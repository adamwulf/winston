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
///   started again after it stopped itself (`restart`).
/// - `engine configuration changed`: the same, at each `AVAudioEngineConfigurationChange`, with
///   the values that changed since the line before (`<key>Before`, `changed`).
/// - `cue played`: each cue the loop plays, with its level.
/// - `reply started`: how long since the engine started, the route changed, the last reply ended
///   and the last cue stopped sounding; the volumes; the route and, on iOS, the microphone's
///   data source and gain; push-to-talk's and the AirPods mute's state.
/// - `mic level`: the microphone's loudest buffer and sample after voice processing, at most
///   every `levelInterval`, only while a reply is being said.
/// - `result during reply`: a recognizer result that came while a reply was being said, how
///   long into its playback, and whether it stopped the reply.
/// - `reply playback`: how each reply ended: its first sound and its stop on the session's clock,
///   whether the voice detector heard voice meanwhile, and the loudest microphone level.
/// - `preview stopped as voice mode starts` and `audio outside voice processing`: the preview
///   player's engine, which plays outside voice processing, playing around voice mode.
///
/// A line written while a pipeline runs carries `session` and `tMs`, as the `voice.timeline`
/// lines do, so the two logs line up. Times since something happened are left out until it has.
/// Counts, levels, times and states only: never what was said or spoken. Main actor only; the
/// microphone tap only records levels, in `MicrophoneLevels`.
@MainActor
final class EchoLog {
    private static let log = Logger(label: "voice.echo")

    /// The shortest time between two `mic level` lines, in seconds. The loop looks every 100 ms,
    /// so they come every 300 ms.
    nonisolated static let levelInterval = 0.25

    private struct LastCue {
        /// The ID `VoiceLoop.play(_:)` gave it.
        let id: Int
        let cue: SoundCue
        /// When it was scheduled, in host time.
        let scheduled: UInt64
        /// When it stopped sounding, in host time: its completion, for a cue that played out, or
        /// when a reply cut it off. Nil until then.
        var ended: UInt64?
        /// Whether a reply cut it off.
        var cutOff = false
    }

    private struct Reply {
        /// Its number in `voice.timeline`.
        let number: Int?
        /// When it was set up, in host time.
        let started: UInt64
        /// When its first buffer was scheduled on the player, in host time; nil until then.
        let firstAudio: () -> UInt64?
        /// The loudest levels of the `mic level` windows taken so far.
        var loudest: MicrophoneLevels.Window?
        /// Results that came while it played.
        var results = 0
        /// How long after its first sound the first of them came.
        var firstResultIntoPlaybackMs: Int?
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
    /// The reply being said; nil when none is.
    private var reply: Reply?
    private var levelLimiter = RateLimiter(interval: EchoLog.levelInterval)

    /// `log` is for tests: by default the `voice.echo` logger.
    init(log: Logger? = nil) {
        logger = log ?? Self.log
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
    /// same engine again, after it stopped itself).
    func logEngineState(_ pipeline: Pipeline, reason: String) {
        let time = TimelineClock.now()
        let state = EngineAudioState(pipeline)
        engineState = state
        var fields = state.fields
        fields["reason"] = reason
        fields["echoCancellation"] = pipeline.hasVoiceProcessing
        fields["sinceEngineStartMs"] = Self.milliseconds(since: engineStartTime, to: time)
        fields["sinceRouteChangeMs"] = Self.milliseconds(since: routeChangeTime, to: time)
        logger.notice("engine audio state", context(pipeline, at: time, fields))
    }

    /// `pipeline`'s engine posted `AVAudioEngineConfigurationChange`. Logs its state now against
    /// the state last logged, before the loop starts it again.
    func configurationChanged(_ pipeline: Pipeline) {
        let time = TimelineClock.now()
        let state = EngineAudioState(pipeline)
        var fields = engineState.map { state.fields(changedFrom: $0) } ?? state.fields
        engineState = state
        fields["sinceEngineStartMs"] = Self.milliseconds(since: engineStartTime, to: time)
        fields["sinceRouteChangeMs"] = Self.milliseconds(since: routeChangeTime, to: time)
        logger.notice("engine configuration changed", context(pipeline, at: time, fields))
    }

    /// The iOS audio route changed. "audio route changed" in `voice.loop` says how.
    func routeChanged() {
        routeChangeTime = TimelineClock.now()
    }

    // MARK: - Cues

    /// `cue` was scheduled as cue `id`, after `leadIn` seconds of silence, behind `queuedBehind`
    /// cues that hadn't finished. `replyPlaying` says whether a reply is being said.
    func cueScheduled(_ cue: SoundCue, id: Int, leadIn: Double, queuedBehind: Int, replyPlaying: Bool, on pipeline: Pipeline) {
        let time = TimelineClock.now()
        lastCue = LastCue(id: id, cue: cue, scheduled: time)
        let level = Self.level(of: cue)
        var fields: [String: CustomStringConvertible] = [
            "cue": "\(cue)",
            "peakDb": level.peakDb,
            "rmsDb": level.rmsDb,
            "cueMs": Int((cue.duration / .milliseconds(1)).rounded()),
            "leadInMs": Int((leadIn * 1000).rounded()),
            "queuedBehind": queuedBehind,
            "replyPlaying": replyPlaying,
            "cueVolume": Self.volume(pipeline.cuePlayer.volume),
            "mixerVolume": Self.volume(pipeline.engine.mainMixerNode.outputVolume),
        ]
        fields["sinceReplyEndMs"] = Self.milliseconds(since: replyEndTime, to: time)
        logger.notice("cue played", context(pipeline, at: time, fields))
    }

    /// Cue `id` stopped sounding at `hostTime`: its completion ran, because it played out or its
    /// player was stopped. The completion of a cue a reply cut off comes after the cut
    /// (`cuesCutOff(ids:)`), and reaches the main actor later still, so the cut's time stands.
    /// One from before the cut means the cue had played out already.
    func cueEnded(id: Int, at hostTime: UInt64) {
        guard let cue = lastCue, cue.id == id else { return }
        if let ended = cue.ended, ended <= hostTime { return }
        lastCue?.ended = hostTime
        lastCue?.cutOff = false
    }

    /// The cue player was just stopped to make way for a reply, cutting off cues `ids`.
    func cuesCutOff(ids: [Int]) {
        guard let cue = lastCue, cue.ended == nil, ids.contains(cue.id) else { return }
        lastCue?.ended = TimelineClock.now()
        lastCue?.cutOff = true
    }

    // MARK: - Replies

    /// A reply was set up at `started`, and its synthesis has started. `firstAudio` tells when
    /// its first buffer was scheduled on the player. `micGate` holds push-to-talk's and the
    /// AirPods mute's state; `cuesUnfinished` the cues that hadn't finished as it started (a
    /// working cue among them is cut off for it); `previewPlaying` whether the preview player's
    /// own engine, outside voice processing, was playing.
    func replyStarted(
        _ pipeline: Pipeline,
        at started: UInt64,
        firstAudio: @escaping () -> UInt64?,
        micGate: [String: CustomStringConvertible],
        cuesUnfinished: [SoundCue],
        previewPlaying: Bool
    ) {
        repliesSinceEngineStart += 1
        reply = Reply(number: pipeline.timeline.replyNumber, started: started, firstAudio: firstAudio)
        // The first level window starts with the reply.
        _ = pipeline.micLevels.take()
        levelLimiter.restart(at: started)

        var fields = micGate
        fields["reply"] = pipeline.timeline.replyNumber
        fields["replySinceEngineStart"] = repliesSinceEngineStart
        fields["sinceEngineStartMs"] = Self.milliseconds(since: engineStartTime, to: started)
        fields["sinceRouteChangeMs"] = Self.milliseconds(since: routeChangeTime, to: started)
        fields["sinceReplyEndMs"] = Self.milliseconds(since: replyEndTime, to: started)
        fields["lastCue"] = lastCue.map { "\($0.cue)" } ?? "none"
        if let lastCue {
            fields["sinceCueScheduledMs"] = TimelineClock.milliseconds(from: lastCue.scheduled, to: started)
            // Nil while it still sounds, or hasn't reported stopping yet.
            fields["sinceCueEndMs"] = Self.milliseconds(since: lastCue.ended, to: started)
            fields["lastCueCutOff"] = lastCue.cutOff
        }
        fields["cuesUnfinished"] = cuesUnfinished.isEmpty ? "none" : cuesUnfinished.map { "\($0)" }.joined(separator: ",")
        fields["speechVolume"] = Self.volume(pipeline.speech.player.volume)
        fields["cueVolume"] = Self.volume(pipeline.cuePlayer.volume)
        fields["mixerVolume"] = Self.volume(pipeline.engine.mainMixerNode.outputVolume)
        fields["pitchShifted"] = !pipeline.speech.pitchShift.bypass
        fields["previewPlaying"] = previewPlaying
        fields["echoCancellation"] = pipeline.hasVoiceProcessing
        // Where the reply starts on the analyzer's timeline, to set against a result's audio
        // range in `voice.timeline`. The fed audio lags the microphone by a tap buffer or so.
        fields["audioMs"] = Self.milliseconds(pipeline.fedAudio.time)
        #if os(iOS)
        fields.merge(Self.routeContext()) { $1 }
        #endif
        logger.notice("reply started", context(pipeline, at: started, fields))
    }

    /// Called every 100 ms. While a reply is being said, writes the microphone's level since the
    /// last `mic level` line, at most every `levelInterval`.
    func poll(_ pipeline: Pipeline) {
        guard let current = reply else { return }
        let time = TimelineClock.now()
        guard levelLimiter.allows(at: time), let window = pipeline.micLevels.take() else { return }
        reply?.loudest = window.merged(with: current.loudest)
        var fields: [String: CustomStringConvertible] = [
            "rmsDb": window.rmsDb,
            "sampleDb": window.sampleDb,
            "buffers": window.buffers,
            "intoReplyMs": TimelineClock.milliseconds(from: current.started, to: time),
        ]
        fields["reply"] = current.number
        fields["intoPlaybackMs"] = Self.milliseconds(since: current.firstAudio(), to: time)
        logger.notice("mic level", context(pipeline, at: time, fields))
    }

    /// A recognizer result came while a reply is being said, giving the transcript `words`
    /// words. `outcome` is `bargeIn` if it stops the reply, or why it was ignored.
    func resultDuringReply(_ pipeline: Pipeline, words: Int, outcome: String) {
        guard let current = reply else { return }
        let time = TimelineClock.now()
        let intoPlayback = Self.milliseconds(since: current.firstAudio(), to: time)
        reply?.results += 1
        if current.results == 0 {
            reply?.firstResultIntoPlaybackMs = intoPlayback
        }
        var fields: [String: CustomStringConvertible] = [
            "words": words,
            "outcome": outcome,
            "intoReplyMs": TimelineClock.milliseconds(from: current.started, to: time),
            "resultsThisReply": current.results + 1,
        ]
        fields["reply"] = current.number
        fields["intoPlaybackMs"] = intoPlayback
        // The loudest levels since the reply started, the window not yet logged included.
        if let loudest = pipeline.micLevels.current()?.merged(with: current.loudest) ?? current.loudest {
            fields["replyRmsDb"] = loudest.rmsDb
            fields["replySampleDb"] = loudest.sampleDb
        }
        logger.notice("result during reply", context(pipeline, at: time, fields))
    }

    /// The reply stopped: it played to its end, or `reason` (as "reply ended" in `voice.loop`
    /// gives it) cut it off. `voiceStarts` counts the voice detector's starts while it played.
    func replyEnded(_ pipeline: Pipeline?, reason: String, micGate: [String: CustomStringConvertible], voiceStarts: Int) {
        guard let ended = reply else { return }
        reply = nil
        let time = TimelineClock.now()
        replyEndTime = time
        let firstAudio = ended.firstAudio()
        var fields = micGate
        fields["reason"] = reason
        fields["reply"] = ended.number
        fields["voiceStarts"] = voiceStarts
        fields["results"] = ended.results
        fields["firstResultIntoPlaybackMs"] = ended.firstResultIntoPlaybackMs
        fields["replyMs"] = TimelineClock.milliseconds(from: ended.started, to: time)
        if let pipeline {
            fields["voiceActive"] = pipeline.timeline.isVoiceActive
            fields["setupTMs"] = pipeline.timeline.clock.milliseconds(at: ended.started)
            fields["firstAudioTMs"] = firstAudio.map { pipeline.timeline.clock.milliseconds(at: $0) }
        }
        fields["synthMs"] = firstAudio.map { TimelineClock.milliseconds(from: ended.started, to: $0) }
        fields["playedMs"] = Self.milliseconds(since: firstAudio, to: time)
        // The last window, which no `mic level` line covers, counts too.
        if let loudest = pipeline?.micLevels.take()?.merged(with: ended.loudest) ?? ended.loudest {
            fields["micRmsDb"] = loudest.rmsDb
            fields["micSampleDb"] = loudest.sampleDb
        }
        logger.notice("reply playback", context(pipeline, at: time, fields))
    }

    // MARK: - Outside voice processing

    /// A preview was playing on the preview player's own engine as voice mode starts; it is
    /// stopped before the microphone is opened.
    func previewStoppedForVoiceMode() {
        logger.notice("preview stopped as voice mode starts", [:])
    }

    /// Audio is about to play outside voice processing while voice mode runs, so echo
    /// cancellation can't take it out of what the microphone hears. `source` says what plays it.
    func audioOutsideVoiceProcessing(source: String, voiceMode: String) {
        logger.notice("audio outside voice processing", ["source": source, "voiceMode": voiceMode])
    }

    // MARK: - Helpers

    /// `fields` with `session` and `tMs` on `pipeline`'s timeline, if there is one.
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
        return context
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
    /// per cue, after the first play has been scheduled, so measuring never delays a cue.
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

/// How loud the microphone is after voice processing, for the `voice.echo` log while a reply is
/// being said: the loudest buffer's RMS level and the loudest sample since the main actor last
/// took them. The whole buffer counts, before push-to-talk's gate, so it measures what echo
/// cancellation lets through even while the gate mutes it. The microphone tap writes it on the
/// audio thread, with atomics only: no lock, no allocation, no logging.
final class MicrophoneLevels: Sendable {
    /// The levels over a stretch of buffers.
    struct Window: Sendable, Equatable {
        /// The loudest buffer's RMS level, in dBFS rounded to a whole number; -120 for silence.
        /// The same measure as `micPeakDb` in `voice.loop`'s "reply ended", but over the whole
        /// buffer rather than what the gate keeps.
        let rmsDb: Int
        /// The loudest single sample, the same way.
        let sampleDb: Int
        /// How many buffers it covers.
        let buffers: Int

        /// The louder of each level, over the buffers of both.
        func merged(with other: Window?) -> Window {
            guard let other else { return self }
            return Window(
                rmsDb: max(rmsDb, other.rmsDb),
                sampleDb: max(sampleDb, other.sampleDb),
                buffers: buffers + other.buffers
            )
        }
    }

    // Levels as their bit patterns: non-negative floats order the same way as their bit
    // patterns, so an integer max works.
    private let loudestBuffer = Atomic<UInt32>(0)
    private let loudestSample = Atomic<UInt32>(0)
    private let buffers = Atomic<Int>(0)

    /// Runs on the audio thread for each microphone buffer.
    func record(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var sum: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
            peak = max(peak, abs(sample))
        }
        loudestBuffer.max((sum / Float(count)).squareRoot().bitPattern, ordering: .relaxed)
        loudestSample.max(peak.bitPattern, ordering: .relaxed)
        buffers.wrappingAdd(1, ordering: .relaxed)
    }

    /// The levels since the last call, and a new window from here; nil if no buffer came. The
    /// three values are taken one after another, so a buffer arriving meanwhile may count
    /// partly toward the next window.
    func take() -> Window? {
        let count = buffers.exchange(0, ordering: .relaxed)
        let rms = loudestBuffer.exchange(0, ordering: .relaxed)
        let peak = loudestSample.exchange(0, ordering: .relaxed)
        guard count > 0 else { return nil }
        return Self.window(rms: rms, peak: peak, buffers: count)
    }

    /// The levels since `take()` last ran, leaving the window going; nil if no buffer came.
    func current() -> Window? {
        let count = buffers.load(ordering: .relaxed)
        guard count > 0 else { return nil }
        return Self.window(
            rms: loudestBuffer.load(ordering: .relaxed),
            peak: loudestSample.load(ordering: .relaxed),
            buffers: count
        )
    }

    private static func window(rms: UInt32, peak: UInt32, buffers: Int) -> Window {
        Window(
            rmsDb: VoiceActivity.decibels(Float(bitPattern: rms)),
            sampleDb: VoiceActivity.decibels(Float(bitPattern: peak)),
            buffers: buffers
        )
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
