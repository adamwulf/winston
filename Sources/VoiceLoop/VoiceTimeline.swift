@preconcurrency import AVFoundation
import Foundation
import Logging
import LogSupport
import Synchronization

/// Milliseconds on one listening session's timeline, from the host clock
/// (`mach_absolute_time`, the clock `AVAudioTime.hostTime` uses), which is monotonic.
struct TimelineClock: Sendable {
    /// When the session started, in host time.
    let start: UInt64

    /// The host clock now.
    static func now() -> UInt64 {
        mach_absolute_time()
    }

    /// Milliseconds from `start` to `hostTime`, negative for a time before it.
    func milliseconds(at hostTime: UInt64) -> Int {
        Self.milliseconds(from: start, to: hostTime)
    }

    /// Milliseconds from one host time to another, rounded; negative when `end` comes first.
    static func milliseconds(from begin: UInt64, to end: UInt64) -> Int {
        let seconds = end >= begin
            ? AVAudioTime.seconds(forHostTime: end - begin)
            : -AVAudioTime.seconds(forHostTime: begin - end)
        return Int((seconds * 1000).rounded())
    }
}

/// Turns the voice detector's buffer-by-buffer answers into spans of voice, for the logs. A
/// span starts at the first buffer called voice after quiet, and ends once the voice has been
/// absent for `quietToEnd` seconds of audio, so the gaps between words don't end it. Time is
/// counted in audio, not on the wall clock. Pure: each buffer carries a `Mark` the caller
/// chooses (its times), and the events hand the marks back.
struct VoiceSpans<Mark> {
    enum Event {
        /// Voice started at this buffer.
        case started(Mark)
        /// The voice that started at `start` stopped at `end`, the first buffer of the quiet
        /// that ended it.
        case ended(start: Mark, end: Mark)
    }

    /// How much quiet audio ends a span, in seconds.
    let quietToEnd: Double
    /// Where the current span started; nil while there is no voice.
    private var start: Mark?
    /// Where the quiet inside the current span began, and how long it has lasted.
    private var quietStart: Mark?
    private var quietSeconds = 0.0

    init(quietToEnd: Double = 0.5) {
        self.quietToEnd = quietToEnd
    }

    /// Whether a span has started and not yet ended.
    var isVoiceActive: Bool { start != nil }

    /// Takes one buffer: whether the detector called it voice, and how many seconds of audio
    /// it holds. Returns the span's start or end, if this buffer is one.
    mutating func process(isVoice: Bool, seconds: Double, mark: Mark) -> Event? {
        if isVoice {
            quietStart = nil
            quietSeconds = 0
            guard start == nil else { return nil }
            start = mark
            return .started(mark)
        }
        guard let spanStart = start else { return nil }
        let quietBegan = quietStart ?? mark
        quietSeconds += seconds
        guard quietSeconds >= quietToEnd else {
            quietStart = quietBegan
            return nil
        }
        start = nil
        quietStart = nil
        quietSeconds = 0
        return .ended(start: spanStart, end: quietBegan)
    }
}

extension VoiceSpans: Sendable where Mark: Sendable {}
extension VoiceSpans.Event: Sendable where Mark: Sendable {}
extension VoiceSpans.Event: Equatable where Mark: Equatable {}

/// What the microphone tap saw, for the timeline log: its first buffer, and where voice starts
/// and stops. The tap runs on the audio thread, so this only records; the main actor takes the
/// records and `VoiceTimeline` writes the lines.
final class MicrophoneTimeline: Sendable {
    /// A buffer's place on both clocks: when it was captured, in host time, and where it starts
    /// on the analyzer's timeline.
    struct Mark: Sendable, Equatable {
        let hostTime: UInt64
        let audioTime: CMTime
    }

    struct FirstBuffer: Sendable, Equatable {
        /// When it was captured. Without `hasCaptureTime`, when the tap was called instead.
        let mark: Mark
        let frames: AVAudioFrameCount
        let sampleRate: Double
        /// When the tap was called, in host time.
        let callbackTime: UInt64
        /// Whether the buffer came with a capture time. An engine rendering offline, as in the
        /// tests, may give none.
        let hasCaptureTime: Bool
    }

    enum VoiceEvent: Sendable, Equatable {
        /// `level` is the buffer's RMS level, `noiseFloor` the level it was judged against.
        case started(Mark, level: Float, noiseFloor: Float?)
        case ended(start: Mark, end: Mark)
    }

    private struct State {
        var awaitingFirstBuffer = true
        var firstBuffer: FirstBuffer?
        var spans = VoiceSpans<Mark>()
        /// Room is reserved so the tap doesn't allocate to append: a few events come each
        /// second, and the main actor takes them every 100 ms.
        var events: [VoiceEvent]

        init() {
            events = []
            events.reserveCapacity(16)
        }
    }

    private let state = Mutex(State())
    /// The host clock; tests pass their own.
    private let now: @Sendable () -> UInt64

    init(now: @escaping @Sendable () -> UInt64 = TimelineClock.now) {
        self.now = now
    }

    /// Records one microphone buffer: `when` is the time the tap was given with it, `audioTime`
    /// where it starts on the analyzer's timeline, and `voice` the detector's reading of it.
    /// Runs on the audio thread.
    func record(
        frames: AVAudioFrameCount,
        sampleRate: Double,
        when: AVAudioTime,
        audioTime: CMTime,
        voice: VoiceActivity.Reading?
    ) {
        let callbackTime = now()
        let hasCaptureTime = when.isHostTimeValid
        let mark = Mark(hostTime: hasCaptureTime ? when.hostTime : callbackTime, audioTime: audioTime)
        state.withLock { state in
            if state.awaitingFirstBuffer {
                state.awaitingFirstBuffer = false
                state.firstBuffer = FirstBuffer(
                    mark: mark,
                    frames: frames,
                    sampleRate: sampleRate,
                    callbackTime: callbackTime,
                    hasCaptureTime: hasCaptureTime
                )
            }
            guard let voice, sampleRate > 0 else { return }
            switch state.spans.process(isVoice: voice.isVoice, seconds: Double(frames) / sampleRate, mark: mark) {
            case .started(let mark)?:
                state.events.append(.started(mark, level: voice.level, noiseFloor: voice.noiseFloor))
            case .ended(let start, let end)?:
                state.events.append(.ended(start: start, end: end))
            case nil:
                break
            }
        }
    }

    /// The tap was installed again, so the next buffer is reported as a first buffer too: its
    /// size and rate can change with the hardware.
    func reportNextBufferAsFirst() {
        state.withLock { $0.awaitingFirstBuffer = true }
    }

    /// The first buffer, once, after it has arrived.
    func takeFirstBuffer() -> FirstBuffer? {
        state.withLock { state in
            defer { state.firstBuffer = nil }
            return state.firstBuffer
        }
    }

    /// Voice starts and ends since the last call, oldest first.
    func takeVoiceEvents() -> [VoiceEvent] {
        state.withLock { state in
            guard !state.events.isEmpty else { return [] }
            // The events go out in the old storage; the tap gets new storage of the same size.
            defer { state.events.removeAll(keepingCapacity: true) }
            return state.events
        }
    }
}

/// The `voice.timeline` log for one listening session: a line for each step from the
/// microphone to the transcript, and from a reply starting to it stopping, so
/// `grep label=voice.timeline` shows where the time goes. See section 5 of
/// docs/research/voice-barge-in-latency.md.
///
/// Every line carries `tMs`, milliseconds since the session started on the host clock (for what
/// the microphone tap or the synthesizer recorded, the time it happened, not the time the line
/// was written), and `session`, the voice loop's run. Lines about the audio also carry
/// `audioMs`, the position on the analyzer's timeline. Counts, levels, times and states only:
/// never what was said or spoken. Main actor only; the audio and synthesizer threads only record.
@MainActor
final class VoiceTimeline {
    private static let log = Logger(label: "voice.timeline")

    /// The voice loop's `runID` for this session.
    let session: Int
    /// Starts when the pipeline is built, before its engine starts.
    let clock: TimelineClock
    /// What the microphone tap records.
    let microphone: MicrophoneTimeline
    private let fedAudio: FedAudioClock
    private let logger: Logger
    /// The host clock.
    private let now: @Sendable () -> UInt64

    private struct Reply {
        /// Counts replies within the session.
        let number: Int
        /// When its first buffer was scheduled on the player, in host time; nil until then.
        let firstAudio: () -> UInt64?
        /// When it was set up, in host time.
        let started: UInt64
        var wroteFirstAudio = false
        /// When `silence` began stopping it, in host time.
        var stopRequested: UInt64?
        /// When a barge-in decided to stop it, in host time.
        var bargeInDecided: UInt64?
    }

    private var replies = 0
    /// The reply being spoken.
    private var reply: Reply?
    /// Whether the latest voice line was "voice started".
    private var isVoiceActive = false
    /// When the latest voice span started, in host time.
    private var lastVoiceStart: UInt64?

    /// `log` and `now` are for tests: by default the `voice.timeline` logger and the host clock.
    init(
        session: Int,
        fedAudio: FedAudioClock,
        log: Logger? = nil,
        now: @escaping @Sendable () -> UInt64 = TimelineClock.now
    ) {
        self.session = session
        self.fedAudio = fedAudio
        logger = log ?? Self.log
        self.now = now
        clock = TimelineClock(start: now())
        microphone = MicrophoneTimeline(now: now)
    }

    // MARK: - Lines

    /// The session is listening. Its `tMs` is 0, when the pipeline was built.
    func started(echoCancellation: Bool, fastResults: Bool, tapFramesRequested: AVAudioFrameCount, analyzerRate: Double) {
        logger.info("timeline started", metadata(at: clock.start, [
            "echoCancellation": echoCancellation,
            "fastResults": fastResults,
            "tapFramesRequested": tapFramesRequested,
            "analyzerRate": Int(analyzerRate.rounded()),
        ]))
    }

    /// The microphone tap is about to be installed again. Writes what the old tap recorded, so
    /// its first buffer isn't replaced unwritten, then reports the new tap's first buffer too:
    /// its size and rate can change with the hardware.
    func willReinstallTap() {
        writeRecorded()
        microphone.reportNextBufferAsFirst()
    }

    /// `Recognizer.start(inputs:)` was called at `called` and returned at `returned`.
    func recognizerStarted(called: UInt64, returned: UInt64) {
        logger.info("recognizer started", metadata(at: returned, [
            "startMs": TimelineClock.milliseconds(from: called, to: returned),
        ]))
    }

    /// Writes what the microphone tap and the reply's playback recorded since the last call.
    /// `VoiceLoop.checkForPause` calls it every 100 ms, and every other line except the first two
    /// calls it first. The lines it writes are dated when each thing happened, so the file is not
    /// in `tMs` order: sort a session's lines by `tMs` to see them in time order.
    func writeRecorded() {
        let time = now()
        if let buffer = microphone.takeFirstBuffer() {
            var extra: [String: CustomStringConvertible] = [
                "tapFrames": buffer.frames,
                "tapRate": Int(buffer.sampleRate.rounded()),
            ]
            if buffer.hasCaptureTime {
                extra["deliveryMs"] = TimelineClock.milliseconds(from: buffer.mark.hostTime, to: buffer.callbackTime)
            }
            logger.info("first mic buffer", metadata(at: buffer.mark.hostTime, audio: buffer.mark.audioTime, extra))
        }
        for event in microphone.takeVoiceEvents() {
            switch event {
            case .started(let mark, let level, let noiseFloor):
                isVoiceActive = true
                lastVoiceStart = mark.hostTime
                var extra: [String: CustomStringConvertible] = [
                    "levelDb": VoiceActivity.decibels(level),
                    "speaking": reply != nil,
                    "detectMs": TimelineClock.milliseconds(from: mark.hostTime, to: time),
                ]
                extra["floorDb"] = noiseFloor.map(VoiceActivity.decibels)
                logger.info("voice started", metadata(at: mark.hostTime, audio: mark.audioTime, extra))
            case .ended(let start, let end):
                isVoiceActive = false
                var extra: [String: CustomStringConvertible] = [:]
                extra["voicedMs"] = Self.milliseconds(end.audioTime - start.audioTime)
                logger.info("voice ended", metadata(at: end.hostTime, audio: end.audioTime, extra))
            }
        }
        if let current = reply, !current.wroteFirstAudio, let firstAudio = current.firstAudio() {
            reply?.wroteFirstAudio = true
            logger.info("speech first audio", metadata(at: firstAudio, [
                "reply": current.number,
                "synthMs": TimelineClock.milliseconds(from: current.started, to: firstAudio),
            ]))
        }
    }

    /// A result the loop applies to the transcript. `isFirst` when it gives an empty transcript
    /// its first word; `words` counts the transcript's words with it applied, and
    /// `firstWordStart` is where its first new word starts on the analyzer's timeline.
    func result(_ piece: TranscriptPiece, words: Int, isFirst: Bool, firstWordStart: CMTime?) {
        writeRecorded()
        let time = now()
        let audio = fedAudio.time
        var extra: [String: CustomStringConvertible] = ["words": words, "final": piece.isFinal]
        extra["rangeEndMs"] = Self.milliseconds(piece.range.end)
        guard isFirst else {
            logger.info("result", metadata(at: time, audio: audio, extra))
            return
        }
        extra["rangeStartMs"] = Self.milliseconds(piece.range.start)
        extra["speaking"] = reply != nil
        if let wordStart = firstWordStart.flatMap(Self.milliseconds), let audioMs = Self.milliseconds(audio) {
            extra["wordStartMs"] = wordStart
            extra["lagMs"] = audioMs - wordStart
        }
        extra["sinceVoiceMs"] = lastVoiceStart.map { TimelineClock.milliseconds(from: $0, to: time) }
        logger.info("first result", metadata(at: time, audio: audio, extra))
    }

    /// A result ignored while a reply plays. `reason` is `noEchoCancellation` or `tooFewWords`.
    func resultIgnored(reason: String, words: Int) {
        writeRecorded()
        logger.info("result ignored", metadata(at: now(), audio: fedAudio.time, [
            "reason": reason,
            "words": words,
        ]))
    }

    /// Words heard over the reply decided to stop it. Its stop follows straight away.
    func bargeInDecided(words: Int) {
        writeRecorded()
        let time = now()
        reply?.bargeInDecided = time
        var extra: [String: CustomStringConvertible] = ["trigger": "words", "words": words]
        extra["replyMs"] = reply.map { TimelineClock.milliseconds(from: $0.started, to: time) }
        extra["sinceVoiceMs"] = lastVoiceStart.map { TimelineClock.milliseconds(from: $0, to: time) }
        logger.info("barge-in decided", metadata(at: time, audio: fedAudio.time, extra))
    }

    /// A reply was set up at `started` and is playing. `queued` replies wait behind it.
    /// `firstAudio` tells when its first buffer was scheduled on the player, once it has been.
    func speechStarted(at started: UInt64, chars: Int, queued: Int, firstAudio: @escaping () -> UInt64?) {
        writeRecorded()
        replies += 1
        reply = Reply(number: replies, firstAudio: firstAudio, started: started)
        logger.info("speech started", metadata(at: now(), [
            "reply": replies,
            "chars": chars,
            "queued": queued,
            "voiceActive": isVoiceActive,
        ]))
    }

    /// The loop began stopping the reply. `reason` is the one "reply ended" gives.
    func speechStopRequested(reason: String) {
        writeRecorded()
        let time = now()
        reply?.stopRequested = time
        var extra: [String: CustomStringConvertible] = ["reason": reason]
        extra["reply"] = reply?.number
        logger.info("speech stop requested", metadata(at: time, extra))
    }

    /// The player has stopped. The speaker goes quiet about `outputLatency` seconds later.
    /// After a barge-in, also writes how long each part of it took.
    func speechStopped(outputLatency: TimeInterval) {
        let time = now()
        // The synthesizer may have scheduled the first buffer since the stop was requested.
        writeRecorded()
        guard let stopped = reply else { return }
        reply = nil
        var extra: [String: CustomStringConvertible] = [
            "reply": stopped.number,
            "outputLatencyMs": Int((outputLatency * 1000).rounded()),
        ]
        extra["stopMs"] = stopped.stopRequested.map { TimelineClock.milliseconds(from: $0, to: time) }
        logger.info("speech stopped", metadata(at: time, extra))

        guard let decided = stopped.bargeInDecided else { return }
        var timeline: [String: CustomStringConvertible] = [
            "resultToStopMs": TimelineClock.milliseconds(from: decided, to: time),
        ]
        if let lastVoiceStart {
            timeline["voiceToResultMs"] = TimelineClock.milliseconds(from: lastVoiceStart, to: decided)
            timeline["voiceToStopMs"] = TimelineClock.milliseconds(from: lastVoiceStart, to: time)
        }
        logger.info("barge-in timeline", metadata(at: time, timeline))
    }

    /// The reply played to its end. `replyEnded` holds the fields of the "reply ended" line.
    func speechFinished(_ replyEnded: [String: CustomStringConvertible]) {
        writeRecorded()
        var extra = replyEnded
        extra["reply"] = reply?.number
        reply = nil
        logger.info("speech finished", metadata(at: now(), extra))
    }

    /// An utterance was sent. `lastVoice` and `lastChange` are when the pause detector last
    /// heard voice and saw the transcript change.
    func utteranceSent(
        words: Int,
        lastVoice: ContinuousClock.Instant?,
        lastChange: ContinuousClock.Instant?,
        endsSentence: Bool
    ) {
        writeRecorded()
        let instant = ContinuousClock.now
        var extra: [String: CustomStringConvertible] = ["words": words, "endsSentence": endsSentence]
        extra["sinceVoiceMs"] = lastVoice.map { Int($0.duration(to: instant) / .milliseconds(1)) }
        extra["sinceChangeMs"] = lastChange.map { Int($0.duration(to: instant) / .milliseconds(1)) }
        logger.info("utterance sent", metadata(at: now(), audio: fedAudio.time, extra))
    }

    /// The utterance in progress was dropped.
    func utteranceDiscarded(words: Int) {
        writeRecorded()
        logger.info("utterance discarded", metadata(at: now(), audio: fedAudio.time, [
            "words": words,
        ]))
    }

    // MARK: - Helpers

    /// The keys every line carries, plus `extra`.
    private func metadata(
        at hostTime: UInt64,
        audio: CMTime? = nil,
        _ extra: [String: CustomStringConvertible]
    ) -> [String: CustomStringConvertible] {
        var metadata = extra
        metadata["tMs"] = clock.milliseconds(at: hostTime)
        metadata["session"] = session
        metadata["audioMs"] = audio.flatMap(Self.milliseconds)
        return metadata
    }

    /// `time` in whole milliseconds; nil when it isn't a number.
    private static func milliseconds(_ time: CMTime) -> Int? {
        guard time.isNumeric else { return nil }
        return Int((time.seconds * 1000).rounded())
    }
}
