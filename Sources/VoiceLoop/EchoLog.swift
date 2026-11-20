@preconcurrency import AVFoundation
import Logging
import LogSupport
import Synchronization

/// The `voice.echo` log: what echo cancellation works with, to tell why it sometimes lets a
/// reply's own sound through to the recognizer and sometimes doesn't
/// (docs/research/echo-cancellation-regression.md). Logging only: nothing here changes what
/// voice mode does. One line per event, at notice level:
///
/// - `engine audio state`: voice processing's settings and the formats on both sides of it, once
///   an engine has started (`reason=start`), a new one has replaced it (`rebuild`), or it has
///   started again after it stopped itself (`restart`), each written after the start's or the
///   restart's work is done. A start's line says what its start check did (`startCheck`).
/// - `engine configuration changed`: the same, for each `AVAudioEngineConfigurationChange`, dated
///   when it came and read once the loop has dealt with it (`handling`), with the values that
///   changed since the line before it (`<key>Before`, `changed`). `voice.loop`'s "audio engine
///   stopped" gives the formats as the engine stopped.
/// - `cue played`: each cue the loop plays, with its level.
/// - `reply started`: how long since the engine started, the route changed, the last reply ended
///   and the last cue stopped sounding; the volumes; the route and, on iOS, the microphone's
///   data source and gain; push-to-talk's and the AirPods mute's state.
/// - `mic level`: the microphone's loudest buffer and sample after voice processing, at most
///   every `levelInterval`, only from a reply's first sound until it stops.
/// - `result during reply`: a recognizer result that came while a reply was being said, how
///   long into its playback, and whether it stopped the reply, was ignored, or was filtered out.
/// - `reply playback`: how each reply ended: its first sound and its stop on the session's clock,
///   whether the voice detector heard voice meanwhile, and the loudest microphone level before
///   its first sound and from then on. Written once the tap has handed over every buffer
///   captured before the reply's end, or `readingsGrace` after it.
/// - `preview stopped as voice mode starts` and `audio outside voice processing`: the preview
///   player's engine, which plays outside voice processing, playing around voice mode.
///
/// Voice mode's time-critical paths (opening push-to-talk's gate and setting where the
/// transcript is consumed, stopping a reply on a barge-in, starting up) call only the methods
/// that note an event: they take the time and a few ids or flags, and queue the event. The
/// lines are written later, off those paths: every 100 ms (`poll(_:)`), once a start is done
/// (`flush()`), and when a pipeline goes (`pipelineEnded(_:)`). Taking the microphone's
/// readings, reading the speech player's first-audio time, measuring cues, reading volumes and
/// the route, and formatting all happen then. Each line is dated when its event happened.
///
/// The levels come from each microphone buffer's reading (`MicrophoneLevels`), counted for a
/// reply by when the buffer was captured against `playbackFrom`, the earliest its sound can
/// reach the microphone (its first buffer's scheduling plus the output latency, see
/// `PlaybackOffset`): buffers from its setup that ended by then (`pre…`), the one that spans it
/// (`onset…`), and those from then on (`mic…`, and the `mic level` lines), up to its end.
/// "Into playback" times count from `playbackFrom` too.
///
/// A line written while a pipeline runs carries `session` and `tMs`, as the `voice.timeline`
/// lines do, so the two logs line up. Times since something happened are left out until it has.
/// Counts, levels, times and states only: never what was said or spoken. Main actor only; the
/// microphone tap only records readings, in `MicrophoneLevels`.
@MainActor
final class EchoLog {
    private static let log = Logger(label: "voice.echo")

    /// The shortest time between two `mic level` lines, in seconds. The loop looks every 100 ms,
    /// so they come every 300 ms.
    nonisolated static let levelInterval = 0.25

    /// How long after a reply ends its "reply playback" line waits for the tap to hand over the
    /// buffers captured before the end, if no buffer captured after it shows they all have, in
    /// seconds. A 4096-frame buffer at 48 kHz is about 85 ms.
    nonisolated static let readingsGrace = 0.5

    /// Push-to-talk's and the AirPods mute's state: while push-to-talk is on and not `talking`,
    /// or while `inputMuted`, the recognizer hears silence.
    struct MicGate {
        var pushToTalk: Bool
        var talking: Bool
        var inputMuted: Bool

        var fields: [String: CustomStringConvertible] {
            ["pushToTalk": pushToTalk, "talking": talking, "inputMuted": inputMuted]
        }
    }

    private struct LastCue {
        /// The ID `VoiceLoop.play(_:)` gave it.
        let id: Int
        let cue: SoundCue
        /// When it was scheduled, in host time.
        let scheduled: UInt64
        /// When it stopped sounding, in host time: its completion, for a cue that played out, or
        /// when the player's stop returned, for one a reply cut off. Nil until then.
        var ended: UInt64?
        /// When the player's stop began, for a cue a reply cut off; nil otherwise.
        var cutStarted: UInt64?
        /// Whether a reply cut it off.
        var cutOff: Bool { cutStarted != nil }
    }

    /// How a reply ended, noted as it did.
    private struct ReplyEnd {
        /// In host time.
        let time: UInt64
        let reason: String
        let micGate: MicGate
        let voiceStarts: Int
        let voiceActive: Bool
    }

    /// A reply being said, or one that has ended and waits for its line.
    private struct Reply {
        /// Tells replies apart in this log.
        let serial: Int
        /// Its number in `voice.timeline`.
        let number: Int?
        /// When it was set up, in host time.
        let started: UInt64
        /// When its first buffer was scheduled on the player, in host time; nil until then.
        /// Takes the playback's lock, so it is read only off the time-critical paths.
        let firstAudio: () -> UInt64?
        let pipeline: Pipeline
        /// The microphone's levels while it was being said.
        var levels: ReplyLevels
        /// How long after its first buffer was scheduled its sound can reach the microphone;
        /// read once that has happened.
        var playbackOffset: PlaybackOffset?
        /// Its first buffer's scheduling plus `playbackOffset`, in host time; nil until then.
        var playbackFrom: UInt64?
        /// Whether a `mic level` line has seen its playback start yet.
        var sawPlaybackStart = false
        /// Microphone buffers whose readings were lost because the main actor fell behind.
        var droppedBuffers = 0
        /// Results that came while it played.
        var results = 0
        /// When the first of them came, in host time.
        var firstResultTime: UInt64?
        /// Nil while it is being said.
        var end: ReplyEnd?
    }

    /// A reply starting, with what changes soon after noted as it started.
    private struct ReplyStart {
        let number: Int?
        let started: UInt64
        let pipeline: Pipeline
        let micGate: MicGate
        let cuesUnfinished: [SoundCue]
        let previewPlaying: Bool
        let repliesSinceEngineStart: Int
        let engineStartTime: UInt64?
        let routeChangeTime: UInt64?
        let replyEndTime: UInt64?
        let lastCue: LastCue?
        /// The fed audio's position on the analyzer's timeline as it started.
        let audio: CMTime
    }

    private struct CueStart {
        let cue: SoundCue
        /// Nil for a closing pipeline's stop cue.
        let id: Int?
        /// When it was scheduled, in host time.
        let time: UInt64
        let leadIn: Double
        let queuedBehind: Int
        let replyPlaying: Bool
        let replyEndTime: UInt64?
        let pipeline: Pipeline
    }

    private struct HeardResult {
        let replySerial: Int
        let replyNumber: Int?
        let replyStarted: UInt64
        /// In host time.
        let time: UInt64
        let words: Int
        let outcome: String
        let resultsThisReply: Int
        let pipeline: Pipeline
    }

    private enum Event {
        case cue(CueStart)
        case replyStarted(ReplyStart)
        case result(HeardResult)
        case previewStopped
    }

    private let logger: Logger
    /// When the running engine last started or restarted, in host time.
    private var engineStartTime: UInt64?
    /// Replies started since then.
    private var repliesSinceEngineStart = 0
    /// The engine's state as last logged, the "before" of its next configuration change.
    private var engineState: EngineAudioState?
    /// When the last route change voice mode saw came, in host time.
    private var routeChangeTime: UInt64?
    /// When the last reply ended, in host time.
    private var replyEndTime: UInt64?
    private var lastCue: LastCue?
    /// Replies so far, for `Reply.serial`.
    private var replies = 0
    /// The reply being said; nil when none is.
    private var reply: Reply?
    /// Replies that have ended, until their "reply playback" line is written. At most
    /// `endedReplyLimit`.
    private var endedReplies: [Reply] = []
    /// Events noted and not yet written, oldest first. At most `eventLimit`.
    private var events: [Event] = []
    /// Events and ended replies dropped because their queue was full, for the next line written.
    private var droppedEvents = 0
    private var levelLimiter = RateLimiter(interval: EchoLog.levelInterval)

    /// The most events queued between two writes. A burst between polls brings a handful.
    nonisolated static let eventLimit = 32
    /// The most ended replies waiting for their line.
    nonisolated static let endedReplyLimit = 8

    /// `log` is for tests: by default the `voice.echo` logger.
    init(log: Logger? = nil) {
        logger = log ?? Self.log
        // Room for the most each queue holds, so noting never allocates.
        events.reserveCapacity(Self.eventLimit)
        endedReplies.reserveCapacity(Self.endedReplyLimit)
    }

    /// Queues `event`, or drops and counts it if the queue is full.
    private func enqueue(_ event: Event) {
        guard events.count < Self.eventLimit else {
            droppedEvents += 1
            return
        }
        events.append(event)
    }

    // MARK: - Engine

    /// An engine has just started or restarted. Only notes the time: the loop calls it right
    /// after the start, then `logEngineState(_:reason:)` once it is done with what follows.
    func noteEngineStart() {
        engineStartTime = TimelineClock.now()
        repliesSinceEngineStart = 0
    }

    /// Logs the state of `pipeline`'s engine, which started at `noteEngineStart()`: `reason` is
    /// `start`, `rebuild` (a new engine while voice mode was already running) or `restart` (the
    /// same engine again, after it stopped itself). For a start or a rebuild, `startCheck` says
    /// what the check for an engine that stopped while starting did: `notNeeded`, `restarted`,
    /// `replaced` (a rebuild follows) or `stopped` (voice mode ended).
    func logEngineState(_ pipeline: Pipeline, reason: String, startCheck: String? = nil) {
        let time = TimelineClock.now()
        let state = EngineAudioState(pipeline)
        engineState = state
        var fields = state.fields
        fields["reason"] = reason
        fields["startCheck"] = startCheck
        fields["echoCancellation"] = pipeline.hasVoiceProcessing
        fields["sinceEngineStartMs"] = Self.milliseconds(since: engineStartTime, to: time)
        fields["sinceRouteChangeMs"] = Self.milliseconds(since: routeChangeTime, to: time)
        logger.notice("engine audio state", context(pipeline, at: time, fields))
    }

    /// An `AVAudioEngineConfigurationChange`, noted as it came.
    struct ConfigurationChange {
        /// In host time.
        fileprivate let time: UInt64
        /// The engine's state as last logged.
        fileprivate let before: EngineAudioState?
        fileprivate let engineStartTime: UInt64?
        fileprivate let routeChangeTime: UInt64?
    }

    /// An engine posted `AVAudioEngineConfigurationChange`. Only notes the time and what was
    /// logged before: the loop calls it as the change comes, deals with the change, then calls
    /// `logConfigurationChange(_:of:handling:)`.
    func noteConfigurationChange() -> ConfigurationChange {
        ConfigurationChange(
            time: TimelineClock.now(),
            before: engineState,
            engineStartTime: engineStartTime,
            routeChangeTime: routeChangeTime
        )
    }

    /// Logs `change` to `pipeline`'s engine, dated when it came: the engine's state now, once the
    /// loop has dealt with it, against the state logged before it. `handling` says what the loop
    /// did: `none` (the engine ran on), `restarted`, `replaced` (a rebuild follows), `stopped`
    /// (voice mode ended) or `devicesChanged` (voice mode ended for new devices).
    func logConfigurationChange(_ change: ConfigurationChange, of pipeline: Pipeline, handling: String) {
        let state = EngineAudioState(pipeline)
        var fields = change.before.map { state.fields(changedFrom: $0) } ?? state.fields
        engineState = state
        fields["handling"] = handling
        fields["sinceEngineStartMs"] = Self.milliseconds(since: change.engineStartTime, to: change.time)
        fields["sinceRouteChangeMs"] = Self.milliseconds(since: change.routeChangeTime, to: change.time)
        logger.notice("engine configuration changed", context(pipeline, at: change.time, fields))
    }

    /// The iOS audio route changed. "audio route changed" in `voice.loop` says how.
    func routeChanged() {
        routeChangeTime = TimelineClock.now()
    }

    // MARK: - Noting events

    /// `cue` has just been scheduled as cue `id`, after `leadIn` seconds of silence, behind
    /// `queuedBehind` cues that hadn't finished. `replyPlaying` says whether a reply is being
    /// said. A nil `id` is the stop cue on a pipeline that has stopped listening
    /// (`closing=true`): it is logged, but no reply follows it, so it isn't kept as the last cue.
    func cueScheduled(_ cue: SoundCue, id: Int?, leadIn: Double, queuedBehind: Int, replyPlaying: Bool, on pipeline: Pipeline) {
        let time = TimelineClock.now()
        if let id {
            lastCue = LastCue(id: id, cue: cue, scheduled: time)
        }
        enqueue(.cue(CueStart(
            cue: cue,
            id: id,
            time: time,
            leadIn: leadIn,
            queuedBehind: queuedBehind,
            replyPlaying: replyPlaying,
            replyEndTime: replyEndTime,
            pipeline: pipeline
        )))
    }

    /// Cue `id` stopped sounding at `hostTime`: its completion ran, because it played out or its
    /// player was stopped. For a cue a reply cut off (`cuesCutOff(ids:stopStarted:stopEnded:)`),
    /// a completion stamped at or after the stop began is the stop's own, and the cut stands; one
    /// stamped before it means the cue had played out already, and that is its end. Its hop to
    /// the main actor can come either side of the cut being noted.
    func cueEnded(id: Int, at hostTime: UInt64) {
        guard let cue = lastCue, cue.id == id else { return }
        if let cutStarted = cue.cutStarted {
            guard hostTime < cutStarted else { return }
            lastCue?.cutStarted = nil
        } else if cue.ended != nil {
            return
        }
        lastCue?.ended = hostTime
    }

    /// The cue player was stopped to make way for a reply, cutting off cues `ids`: the stop
    /// began at `stopStarted` and returned at `stopEnded` (host time). A cue whose natural end
    /// has already been noted wasn't cut off.
    func cuesCutOff(ids: [Int], stopStarted: UInt64, stopEnded: UInt64) {
        guard let cue = lastCue, cue.ended == nil, ids.contains(cue.id) else { return }
        lastCue?.cutStarted = stopStarted
        lastCue?.ended = stopEnded
    }

    /// A reply was set up at `started`, and its synthesis has started. `firstAudio` tells when
    /// its first buffer was scheduled on the player. `cuesUnfinished` are the cues that hadn't
    /// finished as it started (a working cue among them is cut off for it); `previewPlaying`
    /// says whether the preview player's own engine, outside voice processing, was playing.
    func replyStarted(
        _ pipeline: Pipeline,
        at started: UInt64,
        firstAudio: @escaping () -> UInt64?,
        micGate: MicGate,
        cuesUnfinished: [SoundCue],
        previewPlaying: Bool
    ) {
        repliesSinceEngineStart += 1
        replies += 1
        let number = pipeline.timeline.replyNumber
        reply = Reply(
            serial: replies,
            number: number,
            started: started,
            firstAudio: firstAudio,
            pipeline: pipeline,
            levels: ReplyLevels(started: started)
        )
        enqueue(.replyStarted(ReplyStart(
            number: number,
            started: started,
            pipeline: pipeline,
            micGate: micGate,
            cuesUnfinished: cuesUnfinished,
            previewPlaying: previewPlaying,
            repliesSinceEngineStart: repliesSinceEngineStart,
            engineStartTime: engineStartTime,
            routeChangeTime: routeChangeTime,
            replyEndTime: replyEndTime,
            lastCue: lastCue,
            audio: pipeline.fedAudio.time
        )))
    }

    /// A recognizer result came while a reply is being said, the transcript having `words`
    /// words with it. `outcome` is `bargeIn` if it stops the reply, why it was ignored, or
    /// `filtered` if the transcript didn't take it (audio already consumed, or outside a
    /// push-to-talk hold). On a barge-in, call it before stopping the reply.
    func resultDuringReply(words: Int, outcome: String) {
        guard let current = reply else { return }
        let time = TimelineClock.now()
        reply?.results += 1
        if current.firstResultTime == nil {
            reply?.firstResultTime = time
        }
        enqueue(.result(HeardResult(
            replySerial: current.serial,
            replyNumber: current.number,
            replyStarted: current.started,
            time: time,
            words: words,
            outcome: outcome,
            resultsThisReply: current.results + 1,
            pipeline: current.pipeline
        )))
    }

    /// The reply stopped: it played to its end, or `reason` (as "reply ended" in `voice.loop`
    /// gives it) cut it off. `voiceStarts` counts the voice detector's starts while it played,
    /// and `voiceActive` says whether voice was active as it stopped. Its line is written later,
    /// with the readings captured up to now.
    func replyEnded(reason: String, micGate: MicGate, voiceStarts: Int, voiceActive: Bool) {
        guard var ended = reply else { return }
        reply = nil
        let time = TimelineClock.now()
        replyEndTime = time
        ended.end = ReplyEnd(time: time, reason: reason, micGate: micGate, voiceStarts: voiceStarts, voiceActive: voiceActive)
        ended.levels.close(at: time)
        guard endedReplies.count < Self.endedReplyLimit else {
            droppedEvents += 1
            return
        }
        endedReplies.append(ended)
    }

    /// A preview was playing on the preview player's own engine as voice mode starts; it is
    /// stopped before the microphone is opened.
    func previewStoppedForVoiceMode() {
        enqueue(.previewStopped)
    }

    // MARK: - Writing

    /// Called every 100 ms while `pipeline` runs: takes its microphone readings, which keeps
    /// their buffer from filling up, writes the lines noted since the last call and those of the
    /// replies that have ended, and from a reply's first sound until it stops, writes the level
    /// since the last `mic level` line, at most every `levelInterval`. The first comes an
    /// interval after the first sound.
    func poll(_ pipeline: Pipeline) {
        absorbLevels(from: pipeline)
        writeEvents()
        writeEndedReplies(of: pipeline, allIn: false)
        writeLevelLine(for: pipeline)
    }

    /// Writes the lines noted since the last call, for when a start is done.
    func flush() {
        writeEvents()
    }

    /// `pipeline` is gone, with its microphone tap: takes its last readings and writes every
    /// line still waiting for it.
    func pipelineEnded(_ pipeline: Pipeline) {
        absorbLevels(from: pipeline)
        writeEvents()
        writeEndedReplies(of: pipeline, allIn: true)
        if reply?.pipeline === pipeline {
            reply = nil
        }
    }

    /// Audio is about to play outside voice processing while voice mode runs, so echo
    /// cancellation can't take it out of what the microphone hears. `source` says what plays it.
    func audioOutsideVoiceProcessing(source: String, voiceMode: String) {
        logger.notice("audio outside voice processing", context(nil, at: 0, ["source": source, "voiceMode": voiceMode]))
    }

    /// Takes the readings of `pipeline`'s microphone buffers that have come since the last call,
    /// and counts them for its replies.
    private func absorbLevels(from pipeline: Pipeline) {
        let (readings, dropped) = pipeline.micLevels.drain()
        if var current = reply, current.pipeline === pipeline {
            Self.absorb(readings, dropped: dropped, into: &current)
            reply = current
        }
        for index in endedReplies.indices where endedReplies[index].pipeline === pipeline {
            Self.absorb(readings, dropped: dropped, into: &endedReplies[index])
        }
    }

    private static func absorb(_ readings: [MicrophoneLevels.Reading], dropped: Int, into reply: inout Reply) {
        // Read after the readings were taken: if the first buffer hadn't been scheduled by now,
        // none of them was captured after it.
        if reply.playbackFrom == nil, let firstAudio = reply.firstAudio() {
            let offset = PlaybackOffset(reply.pipeline)
            reply.playbackOffset = offset
            reply.playbackFrom = firstAudio &+ offset.hostTime
        }
        for reading in readings {
            reply.levels.add(reading, playbackFrom: reply.playbackFrom)
        }
        reply.droppedBuffers += dropped
    }

    private func writeEvents() {
        guard !events.isEmpty else { return }
        let pending = events
        events.removeAll(keepingCapacity: true)
        for event in pending {
            switch event {
            case .cue(let cue): write(cue)
            case .replyStarted(let start): write(start)
            case .result(let result): write(result)
            case .previewStopped: logger.notice("preview stopped as voice mode starts", context(nil, at: 0, [:]))
            }
        }
    }

    /// Writes the "reply playback" line of each of `pipeline`'s replies that has ended, once the
    /// tap has handed over every buffer captured before its end: once a buffer captured after
    /// it has come, or `readingsGrace` after it if none does (the engine stopped, say). With
    /// `allIn`, the tap is gone, and nothing more will come.
    private func writeEndedReplies(of pipeline: Pipeline, allIn: Bool) {
        let time = TimelineClock.now()
        let grace = AVAudioTime.hostTime(forSeconds: Self.readingsGrace)
        var finished: [Reply] = []
        endedReplies.removeAll { ended in
            guard ended.pipeline === pipeline, let end = ended.end else { return false }
            guard allIn || ended.levels.hasReadingAfterEnd || time >= end.time &+ grace else { return false }
            finished.append(ended)
            return true
        }
        for ended in finished {
            writePlayback(ended)
        }
    }

    private func writeLevelLine(for pipeline: Pipeline) {
        guard let current = reply, current.pipeline === pipeline, let playbackFrom = current.playbackFrom else { return }
        if !current.sawPlaybackStart {
            reply?.sawPlaybackStart = true
            levelLimiter.restart(at: playbackFrom)
        }
        let time = TimelineClock.now()
        guard current.levels.window.buffers > 0, levelLimiter.allows(at: time),
              let window = reply?.levels.takeWindow() else { return }
        var fields: [String: CustomStringConvertible] = [
            "rmsDb": window.rmsDb,
            "sampleDb": window.sampleDb,
            "buffers": window.buffers,
            "intoReplyMs": TimelineClock.milliseconds(from: current.started, to: time),
            "intoPlaybackMs": TimelineClock.milliseconds(from: playbackFrom, to: time),
        ]
        fields["reply"] = current.number
        logger.notice("mic level", context(pipeline, at: time, fields))
    }

    private func write(_ cue: CueStart) {
        let level = Self.level(of: cue.cue)
        var fields: [String: CustomStringConvertible] = [
            "cue": "\(cue.cue)",
            "peakDb": level.peakDb,
            "rmsDb": level.rmsDb,
            "cueMs": Int((cue.cue.duration / .milliseconds(1)).rounded()),
            "leadInMs": Int((cue.leadIn * 1000).rounded()),
            "queuedBehind": cue.queuedBehind,
            "replyPlaying": cue.replyPlaying,
            "closing": cue.id == nil,
            "cueVolume": Self.volume(cue.pipeline.cuePlayer.volume),
            "mixerVolume": Self.volume(cue.pipeline.engine.mainMixerNode.outputVolume),
        ]
        fields["sinceReplyEndMs"] = Self.milliseconds(since: cue.replyEndTime, to: cue.time)
        logger.notice("cue played", context(cue.pipeline, at: cue.time, fields))
    }

    private func write(_ start: ReplyStart) {
        let pipeline = start.pipeline
        var fields = start.micGate.fields
        fields["reply"] = start.number
        fields["replySinceEngineStart"] = start.repliesSinceEngineStart
        fields["sinceEngineStartMs"] = Self.milliseconds(since: start.engineStartTime, to: start.started)
        fields["sinceRouteChangeMs"] = Self.milliseconds(since: start.routeChangeTime, to: start.started)
        fields["sinceReplyEndMs"] = Self.milliseconds(since: start.replyEndTime, to: start.started)
        // A completion stamped before the start can reach the main actor after it: the cue, as
        // its completion has told by now, if it stopped sounding before the reply started.
        var startCue = start.lastCue
        if let lastCue, lastCue.id == startCue?.id, let ended = lastCue.ended, ended <= start.started {
            startCue = lastCue
        }
        fields["lastCue"] = startCue.map { "\($0.cue)" } ?? "none"
        if let lastCue = startCue {
            fields["sinceCueScheduledMs"] = TimelineClock.milliseconds(from: lastCue.scheduled, to: start.started)
            // Nil while it still sounds, or hasn't reported stopping yet.
            fields["sinceCueEndMs"] = Self.milliseconds(since: lastCue.ended, to: start.started)
            fields["lastCueCutOff"] = lastCue.cutOff
        }
        fields["cuesUnfinished"] = start.cuesUnfinished.isEmpty ? "none" : start.cuesUnfinished.map { "\($0)" }.joined(separator: ",")
        // The volumes and the pitch shift as the line is written, a moment after the start.
        fields["speechVolume"] = Self.volume(pipeline.speech.player.volume)
        fields["cueVolume"] = Self.volume(pipeline.cuePlayer.volume)
        fields["mixerVolume"] = Self.volume(pipeline.engine.mainMixerNode.outputVolume)
        fields["pitchShifted"] = !pipeline.speech.pitchShift.bypass
        fields["previewPlaying"] = start.previewPlaying
        fields["echoCancellation"] = pipeline.hasVoiceProcessing
        // Where the reply starts on the analyzer's timeline, to set against a result's audio
        // range in `voice.timeline`. The fed audio lags the microphone by a tap buffer or so.
        fields["audioMs"] = Self.milliseconds(start.audio)
        #if os(iOS)
        fields.merge(Self.routeContext()) { $1 }
        #endif
        logger.notice("reply started", context(pipeline, at: start.started, fields))
    }

    private func write(_ result: HeardResult) {
        var fields: [String: CustomStringConvertible] = [
            "words": result.words,
            "outcome": result.outcome,
            "intoReplyMs": TimelineClock.milliseconds(from: result.replyStarted, to: result.time),
            "resultsThisReply": result.resultsThisReply,
        ]
        fields["reply"] = result.replyNumber
        let replied = reply?.serial == result.replySerial ? reply : endedReplies.first { $0.serial == result.replySerial }
        if let replied {
            if let playbackFrom = replied.playbackFrom, playbackFrom <= result.time {
                fields["intoPlaybackMs"] = TimelineClock.milliseconds(from: playbackFrom, to: result.time)
            }
            // The loudest levels so far, as the line is written.
            fields.merge(Self.levelFields(replied.levels, playbackOffset: replied.playbackOffset)) { $1 }
        }
        logger.notice("result during reply", context(result.pipeline, at: result.time, fields))
    }

    private func writePlayback(_ ended: Reply) {
        guard let end = ended.end else { return }
        let clock = ended.pipeline.timeline.clock
        let firstAudio = ended.firstAudio()
        var fields = end.micGate.fields
        fields["reason"] = end.reason
        fields["reply"] = ended.number
        fields["voiceStarts"] = end.voiceStarts
        fields["voiceActive"] = end.voiceActive
        fields["results"] = ended.results
        if let firstResult = ended.firstResultTime, let playbackFrom = ended.playbackFrom, playbackFrom <= firstResult {
            fields["firstResultIntoPlaybackMs"] = TimelineClock.milliseconds(from: playbackFrom, to: firstResult)
        }
        fields["replyMs"] = TimelineClock.milliseconds(from: ended.started, to: end.time)
        fields["setupTMs"] = clock.milliseconds(at: ended.started)
        // When its first buffer was scheduled; it could be heard `playbackOffsetMs` later.
        fields["firstAudioTMs"] = firstAudio.map { clock.milliseconds(at: $0) }
        fields["synthMs"] = firstAudio.map { TimelineClock.milliseconds(from: ended.started, to: $0) }
        fields["playedMs"] = ended.playbackFrom.map { TimelineClock.milliseconds(from: $0, to: end.time) }
        // The stretch no `mic level` line covered included.
        fields.merge(Self.levelFields(ended.levels, playbackOffset: ended.playbackOffset)) { $1 }
        // False if the line was written before a buffer captured after the end came: after
        // `readingsGrace`, or because the pipeline went.
        fields["levelsComplete"] = ended.levels.hasReadingAfterEnd
        if ended.droppedBuffers > 0 {
            fields["droppedBuffers"] = ended.droppedBuffers
        }
        logger.notice("reply playback", context(ended.pipeline, at: end.time, fields))
    }

    // MARK: - Helpers

    /// `fields` with `session` and `tMs` on `pipeline`'s timeline, if there is one, and
    /// `droppedEvents`, the events and ended replies dropped since the last line said so.
    private func context(
        _ pipeline: Pipeline?,
        at hostTime: UInt64,
        _ fields: [String: CustomStringConvertible]
    ) -> [String: CustomStringConvertible] {
        var context = fields
        if let pipeline {
            context["session"] = pipeline.timeline.session
            context["tMs"] = pipeline.timeline.clock.milliseconds(at: hostTime)
        }
        if droppedEvents > 0 {
            context["droppedEvents"] = droppedEvents
            droppedEvents = 0
        }
        return context
    }

    /// The loudest levels of `levels`, with `prefix`: `<prefix>RmsDb` and `<prefix>SampleDb`.
    /// Nothing without a buffer.
    private static func levelFields(_ levels: LevelSummary, prefix: String) -> [String: CustomStringConvertible] {
        guard levels.buffers > 0 else { return [:] }
        return [prefix + "RmsDb": levels.rmsDb, prefix + "SampleDb": levels.sampleDb]
    }

    /// A reply's levels before it could be heard (`pre…`), across that moment (`onset…`), and
    /// after it (`mic…`), with where the split was: `playbackFrom` names what it adds up, and
    /// `playbackOffsetMs` is the latency added to the first buffer's scheduling.
    private static func levelFields(_ levels: ReplyLevels, playbackOffset: PlaybackOffset?) -> [String: CustomStringConvertible] {
        var fields = levelFields(levels.pre, prefix: "pre")
        fields.merge(levelFields(levels.onset, prefix: "onset")) { $1 }
        fields.merge(levelFields(levels.playback, prefix: "mic")) { $1 }
        if let playbackOffset {
            fields["playbackFrom"] = playbackOffset.source
            fields["playbackOffsetMs"] = String(format: "%.1f", playbackOffset.seconds * 1000)
        }
        return fields
    }

    /// Milliseconds from `start` to `end`; nil without a start.
    private static func milliseconds(since start: UInt64?, to end: UInt64) -> Int? {
        start.map { TimelineClock.milliseconds(from: $0, to: end) }
    }

    /// `time` in whole milliseconds; nil when it isn't a number.
    private static func milliseconds(_ time: CMTime) -> Int? {
        guard time.isNumeric else { return nil }
        return Int((time.seconds * 1000).rounded())
    }

    /// A volume or gain, to two decimals.
    private static func volume(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    /// Each cue's level, measured the first time it is logged. A cue's sound is fixed.
    private static var cueLevels: [SoundCue: (peakDb: Int, rmsDb: Int)] = [:]

    /// The loudest sample and the RMS level of `cue` as it is rendered, in dBFS. Rendered once
    /// per cue, when its line is first written, off the time-critical paths.
    private static func level(of cue: SoundCue) -> (peakDb: Int, rmsDb: Int) {
        if let level = cueLevels[cue] {
            return level
        }
        let samples = cue.samples(sampleRate: 48_000)
        var peak: Float = 0
        var sum: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            sum += sample * sample
        }
        let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
        let level = (peakDb: VoiceActivity.decibels(peak), rmsDb: VoiceActivity.decibels(rms))
        cueLevels[cue] = level
        return level
    }

    #if os(iOS)
    /// The route a reply plays through and what the microphone hears it with: `route` is
    /// `speaker`, `receiver`, `bluetooth`, `headphones`, `car`, `airPlay`, `usb`, `none` or
    /// `other`, from the first output. Also the output volume, the input data source's name,
    /// polar pattern and orientation, the input gain and whether it can be set, and whether
    /// another app's audio plays, which no echo canceller hears as a reference.
    private static func routeContext(_ session: AVAudioSession = .sharedInstance()) -> [String: CustomStringConvertible] {
        let route = session.currentRoute
        let source = session.inputDataSource
        func portTypes(_ ports: [AVAudioSessionPortDescription]) -> String {
            ports.isEmpty ? "none" : ports.map(\.portType.rawValue).joined(separator: "+")
        }
        return [
            "route": routeKind(route.outputs.first?.portType),
            "inputs": portTypes(route.inputs),
            "outputs": portTypes(route.outputs),
            "outputVolume": volume(session.outputVolume),
            "inputGain": volume(session.inputGain),
            "inputGainSettable": session.isInputGainSettable,
            "inputDataSource": source?.dataSourceName ?? "none",
            "polarPattern": source?.selectedPolarPattern?.rawValue ?? "none",
            "micOrientation": source?.orientation?.rawValue ?? "none",
            "otherAudioPlaying": session.isOtherAudioPlaying,
        ]
    }

    /// The kind of output `port` is, for `routeContext`.
    private static func routeKind(_ port: AVAudioSession.Port?) -> String {
        guard let port else { return "none" }
        switch port {
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "receiver"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "bluetooth"
        case .headphones: return "headphones"
        case .carAudio: return "car"
        case .airPlay: return "airPlay"
        case .usbAudio: return "usb"
        default: return "other"
        }
    }
    #endif
}

/// How long after a reply's first buffer is scheduled on the player its sound can reach the
/// microphone: the output's latency, and on iOS the I/O buffer too, since the buffer is mixed
/// in at the next render pass. Read off the time-critical paths.
struct PlaybackOffset: Equatable {
    /// In seconds.
    let seconds: Double
    /// What it adds to the first buffer's scheduling, for the log's `playbackFrom`.
    let source: String

    var hostTime: UInt64 {
        AVAudioTime.hostTime(forSeconds: seconds)
    }

    @MainActor init(_ pipeline: Pipeline) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let seconds = session.outputLatency + session.ioBufferDuration
        source = "firstScheduled+outputLatency+ioBuffer"
        #else
        let seconds = pipeline.engine.outputNode.presentationLatency
        source = "firstScheduled+outputLatency"
        #endif
        self.seconds = seconds.isFinite && seconds > 0 ? seconds : 0
    }
}

/// Lets an event through at most once per interval, by the host clock: for log lines that
/// would otherwise come with every poll.
struct RateLimiter {
    /// The shortest time between two events let through, in host time units.
    private let interval: UInt64
    /// When the last event was let through, in host time.
    private var last: UInt64?

    /// `interval` is in seconds.
    init(interval: Double) {
        self.interval = AVAudioTime.hostTime(forSeconds: interval)
    }

    /// Whether an event at `hostTime` goes through; if it does, it counts as the last.
    mutating func allows(at hostTime: UInt64) -> Bool {
        if let last, hostTime < last + interval {
            return false
        }
        last = hostTime
        return true
    }

    /// Counts `hostTime` as the last event let through, so the next goes through an interval
    /// after it.
    mutating func restart(at hostTime: UInt64) {
        last = hostTime
    }
}

/// How loud each microphone buffer is after voice processing, for the `voice.echo` log: its RMS
/// level and its loudest sample, with when it was captured. The whole buffer counts, before
/// push-to-talk's gate, so it measures what echo cancellation lets through even while the gate
/// mutes it.
///
/// A ring of readings with one writer, the microphone tap on the audio thread, and one reader,
/// the main actor, which takes them every 100 ms. Each reading is written whole into its slot
/// before the write count is published, and the reader takes whole readings up to that count,
/// so a buffer is never split between two takes. The tap neither locks nor allocates; when the
/// ring is full it drops the reading and counts it. A tap's blocks run one at a time, so there
/// is only ever one writer.
final class MicrophoneLevels: @unchecked Sendable {
    // `@unchecked`: the slots are plain memory, shared between the one writer and the one
    // reader through the two counts' release and acquire, as described above.

    /// One buffer's levels.
    struct Reading: Sendable, Equatable {
        /// When its first frame was captured, in host time.
        let captureTime: UInt64
        /// How long it lasts, in host time units.
        let duration: UInt64
        /// Its RMS level, on a full scale of 1.
        let rms: Float
        /// Its loudest sample, the same way.
        let peak: Float
    }

    /// How many readings the ring holds: over 10 seconds of 4096-frame buffers at 48 kHz.
    static let capacity = 128

    /// Each slot's capture time.
    private let times: UnsafeMutablePointer<UInt64>
    /// Each slot's duration.
    private let durations: UnsafeMutablePointer<UInt64>
    /// Each slot's RMS level and loudest sample, as their bit patterns.
    private let levels: UnsafeMutablePointer<UInt64>
    /// Readings written since the start. Only the writer changes it.
    private let written = Atomic<Int>(0)
    /// Readings taken since the start. Only the reader changes it.
    private let taken = Atomic<Int>(0)
    /// Readings dropped because the ring was full, since the last take.
    private let dropped = Atomic<Int>(0)

    init() {
        times = .allocate(capacity: Self.capacity)
        times.initialize(repeating: 0, count: Self.capacity)
        durations = .allocate(capacity: Self.capacity)
        durations.initialize(repeating: 0, count: Self.capacity)
        levels = .allocate(capacity: Self.capacity)
        levels.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        times.deallocate()
        durations.deallocate()
        levels.deallocate()
    }

    /// Runs on the audio thread for each microphone buffer: `count` samples lasting `duration`
    /// (host time units), the first captured at `captureTime` (host time).
    func record(_ samples: UnsafePointer<Float>, count: Int, capturedAt captureTime: UInt64, duration: UInt64) {
        guard count > 0 else { return }
        var sum: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = (sum / Float(count)).squareRoot()
        let next = written.load(ordering: .relaxed)
        guard next - taken.load(ordering: .acquiring) < Self.capacity else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let slot = next % Self.capacity
        times[slot] = captureTime
        durations[slot] = duration
        levels[slot] = UInt64(rms.bitPattern) << 32 | UInt64(peak.bitPattern)
        written.store(next &+ 1, ordering: .releasing)
    }

    /// The readings written since the last call, oldest first, and how many were dropped since
    /// then. Main actor only: there must be one reader.
    func drain() -> (readings: [Reading], dropped: Int) {
        let first = taken.load(ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        var readings: [Reading] = []
        readings.reserveCapacity(end - first)
        for index in first..<end {
            let slot = index % Self.capacity
            let bits = levels[slot]
            readings.append(Reading(
                captureTime: times[slot],
                duration: durations[slot],
                rms: Float(bitPattern: UInt32(truncatingIfNeeded: bits >> 32)),
                peak: Float(bitPattern: UInt32(truncatingIfNeeded: bits))
            ))
        }
        taken.store(end, ordering: .releasing)
        return (readings, dropped.exchange(0, ordering: .relaxed))
    }
}

/// The loudest levels over some microphone buffers.
struct LevelSummary: Equatable {
    /// The loudest buffer's RMS level, on a full scale of 1.
    private(set) var rms: Float = 0
    /// The loudest single sample, the same way.
    private(set) var peak: Float = 0
    /// How many buffers it covers.
    private(set) var buffers = 0

    mutating func add(_ reading: MicrophoneLevels.Reading) {
        rms = max(rms, reading.rms)
        peak = max(peak, reading.peak)
        buffers += 1
    }

    /// `rms` in dBFS rounded to a whole number, -120 for silence: the same measure as
    /// `micPeakDb` in `voice.loop`'s "reply ended", but over the whole buffer rather than what
    /// the gate keeps.
    var rmsDb: Int { VoiceActivity.decibels(rms) }
    /// `peak` the same way.
    var sampleDb: Int { VoiceActivity.decibels(peak) }
}

/// One reply's microphone levels, by when each buffer was captured against `playbackFrom`, the
/// earliest the reply's sound can reach the microphone: buffers that ended by then (`pre`),
/// the one that spans it (`onset`), and those that began at or after it (`playback`, and
/// `window`, since the last `mic level` line). Only buffers captured from the reply's setup up
/// to its end, once it has one, are the reply's.
struct ReplyLevels: Equatable {
    /// When the reply was set up, in host time.
    let started: UInt64
    /// When it ended, in host time; nil while it is being said.
    private(set) var end: UInt64?
    /// Room noise and the user, before the reply could be heard.
    private(set) var pre = LevelSummary()
    /// Partly before and partly after.
    private(set) var onset = LevelSummary()
    /// After the reply could be heard: what echo cancellation let through, the user, and noise.
    private(set) var playback = LevelSummary()
    private(set) var window = LevelSummary()

    init(started: UInt64) {
        self.started = started
    }

    /// Whether a reading captured at or after the end has come. The tap hands buffers over in
    /// the order they were captured, so every buffer captured before the end has come too.
    private(set) var hasReadingAfterEnd = false

    /// The reply ended at `time` (host time).
    mutating func close(at time: UInt64) {
        end = time
    }

    /// Counts `reading` against `playbackFrom` (host time): nil if the reply's first buffer
    /// hadn't been scheduled when the reading was taken, so every reading counts as `pre`.
    mutating func add(_ reading: MicrophoneLevels.Reading, playbackFrom: UInt64?) {
        if let end, reading.captureTime >= end {
            hasReadingAfterEnd = true
            return
        }
        guard reading.captureTime >= started else { return }
        guard let playbackFrom else {
            pre.add(reading)
            return
        }
        if reading.captureTime >= playbackFrom {
            playback.add(reading)
            window.add(reading)
        } else if reading.captureTime &+ reading.duration <= playbackFrom {
            pre.add(reading)
        } else {
            onset.add(reading)
        }
    }

    /// The levels since the last call, and a new window from here; nil if no buffer since.
    mutating func takeWindow() -> LevelSummary? {
        guard window.buffers > 0 else { return nil }
        defer { window = LevelSummary() }
        return window
    }
}

/// What echo cancellation works with in one engine, for the `voice.echo` log: voice
/// processing's settings on the input and output nodes, the ducking of other audio, the formats
/// on both sides of voice processing, the I/O latencies, and on iOS the session's rate and I/O
/// buffer. Compared before and after each configuration change.
struct EngineAudioState: Equatable {
    /// Each value by its key in the log.
    var values: [String: String]

    /// The values as log fields.
    var fields: [String: CustomStringConvertible] {
        values.mapValues { $0 as CustomStringConvertible }
    }

    /// The keys whose values differ from `before`, in order. A key on one side only counts.
    func changes(from before: EngineAudioState) -> [String] {
        Set(values.keys).union(before.values.keys)
            .filter { values[$0] != before.values[$0] }
            .sorted()
    }

    /// The fields of a line about a change from `before`: every value now, and for each one
    /// that changed its value before, as `<key>Before` (`none` if it had none); `changed` lists
    /// the keys that changed, or is `none`.
    func fields(changedFrom before: EngineAudioState) -> [String: CustomStringConvertible] {
        var fields = self.fields
        let changes = changes(from: before)
        for key in changes {
            fields[key + "Before"] = before.values[key] ?? "none"
        }
        fields["changed"] = changes.isEmpty ? "none" : changes.joined(separator: ",")
        return fields
    }
}

extension EngineAudioState {
    /// `pipeline`'s engine as it is now. `micFormat` is the microphone's hardware format and
    /// `tapFormat` the input's client side; `outputFormat` is the output's client side (the main
    /// mixer's connection to it) and `deviceFormat` its hardware side. `formatsMatch` says
    /// whether the two client sides, which voice processing pairs up, have the same rate and
    /// channel count.
    @MainActor init(_ pipeline: Pipeline) {
        let engine = pipeline.engine
        let input = engine.inputNode
        let output = engine.outputNode
        let tap = input.outputFormat(forBus: 0)
        let outputClient = output.inputFormat(forBus: 0)
        let ducking = input.voiceProcessingOtherAudioDuckingConfiguration
        let duckingLevel = switch ducking.duckingLevel {
        case .default: "default"
        case .min: "min"
        case .mid: "mid"
        case .max: "max"
        @unknown default: "\(ducking.duckingLevel.rawValue)"
        }
        func format(_ format: AVAudioFormat) -> String {
            "\(Int(format.sampleRate.rounded()))/\(format.channelCount)"
        }
        func milliseconds(_ seconds: TimeInterval) -> String {
            String(format: "%.1f", seconds * 1000)
        }
        var values = [
            "vpInput": "\(input.isVoiceProcessingEnabled)",
            "vpOutput": "\(output.isVoiceProcessingEnabled)",
            "vpBypassed": "\(input.isVoiceProcessingBypassed)",
            "vpAGC": "\(input.isVoiceProcessingAGCEnabled)",
            "vpInputMuted": "\(input.isVoiceProcessingInputMuted)",
            "duckingAdvanced": "\(ducking.enableAdvancedDucking)",
            "duckingLevel": duckingLevel,
            "micFormat": format(input.inputFormat(forBus: 0)),
            "tapFormat": format(tap),
            "outputFormat": format(outputClient),
            "deviceFormat": format(output.outputFormat(forBus: 0)),
            "formatsMatch": "\(tap.sampleRate == outputClient.sampleRate && tap.channelCount == outputClient.channelCount)",
            "inputLatencyMs": milliseconds(input.presentationLatency),
            "outputLatencyMs": milliseconds(output.presentationLatency),
            "running": "\(engine.isRunning)",
        ]
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        values["sessionRate"] = "\(Int(session.sampleRate.rounded()))"
        values["ioBufferMs"] = milliseconds(session.ioBufferDuration)
        #endif
        self.init(values: values)
    }
}
