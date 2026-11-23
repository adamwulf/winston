import Foundation
import Logging
import LogSupport
import Observation
import TelegramLink
import VoiceLoop

/// Speak IPA, the message list's menu item: Apple's on-device model writes the IPA for each word
/// of a message, and the Kokoro voice says it, so its pronunciation can be heard rather than
/// Kokoro's own. Made by `AppModel`, as `speakIPA`.
///
/// The message is readied as plain words (`SpeakIPAText.normalized(_:)`) and cut into chunks
/// (`SpeakIPAText.chunks(in:)`), a small first one so it starts soon. The model transcribes them
/// one at a time, in order, each in a minute at most, and each chunk plays as soon as it is ready
/// and the one before has played (`VoiceLoop.startIPASpeech(request:onFirstSound:onEnded:)`). A
/// word whose IPA Kokoro can't say is said as written, as is a chunk with less than half its
/// words said so, or one the model failed on (`SpeakIPAText.speech(of:transcribed:symbols:)`),
/// including a timeout of the model's own. When Speak IPA's own minute runs out, the rest of the
/// message is said as written: a model that stalled once would likely stall again. What the
/// model wrote for a message is kept for the last `cachedMessages` messages, so saying one again
/// starts at once; with every chunk kept, it needs no model at all.
///
/// One message is said at a time: another message's Speak IPA replaces it, and the same
/// message's stops it, as does `stop()`, another chat being shown, logging out, or anything that
/// cuts off a preview, such as Speak or voice mode starting. It plays only while voice mode is
/// off, and only with a Kokoro voice ready; otherwise, or when the model can't run, the message
/// says why (`note(for:)`), as it does once a message has played with some of it said as
/// written.
///
/// Each step is logged under `app.speakipa` at notice level, and a failure or a timeout at
/// warning, with the request's number (counted across messages), chunk numbers, counts and times:
/// never the text or the IPA.
@MainActor
@Observable
public final class SpeakIPA {
    private static let log = Logger(label: "app.speakipa")

    /// How long the model may take over one chunk before Speak IPA gives up on it. A chunk takes
    /// about 2 to 6 s on a Mac.
    package static let defaultTimeout: Duration = .seconds(60)
    /// How many messages' IPA is kept.
    static let cachedMessages = 20

    /// Where the message being said is.
    public enum Phase: Equatable, Sendable {
        /// The model is writing the first chunk's IPA.
        case preparing
        /// The message is playing; later chunks may still be being written.
        case speaking
    }

    /// A message, by its chat and its ID: IDs are only unique within a chat.
    private struct MessageKey: Hashable {
        let chat: ChatID
        let message: MessageID

        init(_ message: ChatMessage) {
            self.init(chat: message.chatID, message: message.id)
        }

        init(chat: ChatID, message: MessageID) {
            self.chat = chat
            self.message = message
        }
    }

    /// Whether the app is in voice mode, which the loop alone doesn't say: after a failure it
    /// can be off while the app still offers to resume. `AppModel` sets it.
    @ObservationIgnored var isVoiceModeOn: @MainActor () -> Bool = { false }

    /// The message being said, and where it is; nil while none is.
    private var current: (key: MessageKey, phase: Phase)?
    /// What to tell Adam about a message, under it, until another Speak IPA starts or it is
    /// dismissed.
    private var currentNote: (key: MessageKey, text: String)?

    @ObservationIgnored private let voiceLoop: VoiceLoop
    @ObservationIgnored private let transcriber: any IPATranscriber
    @ObservationIgnored private let timeout: Duration
    /// The run under way: nil while none is.
    @ObservationIgnored private var run: Run?
    /// Numbers the requests from 1, for the logs.
    @ObservationIgnored private var requestCount = 0
    /// What the model wrote for each chunk it was asked about, by message and chunk, for the
    /// messages in `cacheOrder`. Only answers that were said as IPA are kept.
    @ObservationIgnored private var cache: [MessageKey: [String: [TranscribedWord]]] = [:]
    /// The messages in `cache`, the one used longest ago first.
    @ObservationIgnored private var cacheOrder: [MessageKey] = []

    /// One message being said.
    private struct Run {
        let number: Int
        var key: MessageKey
        let chunks: [String]
        let speech: IPASpeech
        let started: ContinuousClock.Instant
        /// The chunk the model is writing, or the number of chunks once all are queued.
        var next = 0
        var chunkStarted = ContinuousClock.now
        var request: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var words = 0
        var wordsWithIPA = 0
        var writtenChunks = 0
        /// The first failure that put a chunk back to its written form, for the note.
        var failure: PronunciationSuggestionError?
    }

    init(voiceLoop: VoiceLoop, transcriber: any IPATranscriber, timeout: Duration = defaultTimeout) {
        self.voiceLoop = voiceLoop
        self.transcriber = transcriber
        self.timeout = timeout
    }

    /// Where `message` is, while it is being said; nil otherwise.
    public func phase(for message: ChatMessage) -> Phase? {
        guard let current, current.key == MessageKey(message) else { return nil }
        return current.phase
    }

    /// What to tell Adam under `message`, if anything: why Speak IPA couldn't say it, or how much
    /// of it was said as written.
    public func note(for message: ChatMessage) -> String? {
        guard let currentNote, currentNote.key == MessageKey(message) else { return nil }
        return currentNote.text
    }

    /// Hides the note, for its dismiss button.
    public func dismissNote() {
        currentNote = nil
    }

    /// Says `message`'s spoken text with the model's IPA, for the menu item, or stops it if it is
    /// being said. Replaces any other message being said.
    public func toggle(_ message: ChatMessage) {
        if run?.key == MessageKey(message) {
            stop(reason: "tappedAgain")
        } else {
            start(message)
        }
    }

    /// Stops the message being said, if any, for its stop button.
    public func stop() {
        stop(reason: "stopButton")
    }

    /// Stops `message` if it is being said, and does nothing otherwise, for the Stop Speaking IPA
    /// menu item: the message may have finished while the menu was open.
    public func stop(_ message: ChatMessage) {
        guard run?.key == MessageKey(message) else { return }
        stop(reason: "stopMenuItem")
    }

    /// Stops the message being said if it isn't in `chat`, for when another chat is shown.
    func stop(unlessIn chat: ChatID?) {
        guard let run, run.key.chat != chat else { return }
        stop(reason: "chatChanged")
    }

    /// The message `oldID` in `chat` is now `newID`, as a message Adam sent has once Telegram
    /// confirms it: its speech, note and IPA follow it.
    func messageIDChanged(in chat: ChatID, from oldID: MessageID, to newID: MessageID) {
        let old = MessageKey(chat: chat, message: oldID)
        let new = MessageKey(chat: chat, message: newID)
        if var run, run.key == old {
            run.key = new
            self.run = run
        }
        if let current, current.key == old {
            self.current = (new, current.phase)
        }
        if let currentNote, currentNote.key == old {
            self.currentNote = (new, currentNote.text)
        }
        if let kept = cache.removeValue(forKey: old) {
            cache[new] = kept
            cacheOrder = cacheOrder.map { $0 == old ? new : $0 }
        }
    }

    /// Stops, and forgets the note and every message's IPA, for a logout.
    func reset() {
        stop(reason: "sessionEnded")
        currentNote = nil
        cache = [:]
        cacheOrder = []
    }

    // MARK: - Starting

    private func start(_ message: ChatMessage) {
        let replaced = run?.number
        if run != nil {
            stop(reason: "replaced")
        }
        currentNote = nil
        requestCount += 1
        let number = requestCount
        let key = MessageKey(message)
        let chunks = SpeakIPAText.chunks(in: SpeakIPAText.normalized(message.spokenText))
        // A message whose every chunk is kept needs no model, nor asks after it.
        let needsModel = chunks.contains { cache[key]?[$0] == nil }
        let availability = needsModel ? transcriber.availability : nil
        var fields: [String: CustomStringConvertible] = [
            "request": number,
            "messageChars": message.spokenText.count,
            "chunks": chunks.count,
            "words": chunks.reduce(0) { $0 + SpeakIPAText.words(of: $1).count },
            "availability": availability?.logName ?? "notNeeded",
            "cached": cache[key] != nil,
        ]
        if let replaced {
            fields["replacedRequest"] = replaced
        }
        Self.log.notice("speak ipa requested", fields)

        if let reason = reasonCantSpeak(availability: availability ?? .available, chunks: chunks) {
            Self.log.warning("speak ipa can't start", ["request": number, "reason": reason.logName])
            currentNote = (key, reason.message)
            return
        }
        let speech: IPASpeech
        do {
            speech = try voiceLoop.startIPASpeech(request: number) { [weak self] in
                self?.firstSound(request: number)
            } onEnded: { [weak self] end in
                self?.ended(request: number, end: end)
            }
        } catch {
            let reason: CantSpeak = switch error as? IPASpeechError {
            case .voiceModeOn: .voiceModeOn
            case .kokoroNotReady: .kokoro(SuggestionPlayback(voiceLoop))
            case nil: .playbackFailed
            }
            Self.log.warning("speak ipa can't start", error.logCodes(["request": "\(number)", "reason": reason.logName]))
            currentNote = (key, reason.message)
            return
        }
        run = Run(number: number, key: key, chunks: chunks, speech: speech, started: .now)
        current = (key, .preparing)
        // Recently used, so it is the last to go from the cache.
        if cache[key] != nil {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
        }
        transcribeNext()
    }

    /// Why Speak IPA can't say a message with `chunks` now, if it can't: checked before anything
    /// plays, in the order Adam would fix them.
    private func reasonCantSpeak(availability: PronunciationSuggesterAvailability, chunks: [String]) -> CantSpeak? {
        if isVoiceModeOn() || voiceLoop.state != .off {
            return .voiceModeOn
        }
        let playback = SuggestionPlayback(voiceLoop)
        if playback != .plays {
            return .kokoro(playback)
        }
        if case .unavailable(let reason) = availability {
            return .model(reason)
        }
        if chunks.isEmpty {
            return .nothingToSay
        }
        return nil
    }

    // MARK: - Transcribing

    /// Asks the model for the next chunk's IPA, or says it at once from the cache, until every
    /// chunk is queued.
    private func transcribeNext() {
        guard var run else { return }
        while run.next < run.chunks.count, let cached = cache[run.key]?[run.chunks[run.next]] {
            run.chunkStarted = .now
            self.run = run
            guard say(chunk: run.next, transcribed: cached, cached: true) else { return }
            guard let updated = self.run else { return }
            run = updated
        }
        guard run.next < run.chunks.count else {
            finishQueueing()
            return
        }
        let index = run.next
        let chunk = run.chunks[index]
        let number = run.number
        run.chunkStarted = .now
        run.request = Task { [transcriber] in
            let result: Result<[TranscribedWord], any Error>
            do {
                result = .success(try await transcriber.transcribe(chunk, request: number, chunkIndex: index))
            } catch {
                result = .failure(error)
            }
            self.answered(result, request: number, chunk: index)
        }
        run.deadline = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.timedOut(request: number, chunk: index)
        }
        self.run = run
    }

    /// The model's answer for chunk `index` of request `number`, if Speak IPA still waits for it;
    /// dropped otherwise.
    private func answered(_ result: Result<[TranscribedWord], any Error>, request number: Int, chunk index: Int) {
        guard var run, run.number == number, run.next == index, run.request != nil else {
            Self.log.notice("speak ipa answer dropped", ["request": number, "chunk": index])
            return
        }
        run.request = nil
        run.deadline?.cancel()
        run.deadline = nil
        self.run = run
        switch result {
        case .success(let transcribed):
            guard say(chunk: index, transcribed: transcribed, cached: false) else { return }
        case .failure(let error):
            // A cancel of Speak IPA's own leaves no request awaited, so its answer stops at the
            // guard above. One that passes it came from elsewhere (the system can cancel a
            // request): a failure like any other, so the message goes on.
            let reason = error as? PronunciationSuggestionError ?? .failed
            // Codes only: a transcriber's error can quote the text. To be said as written, unless
            // the speech has ended ("chunk not queued").
            Self.log.warning("speak ipa chunk failed", error.logCodes([
                "request": "\(number)",
                "chunk": "\(index)",
                "reason": reason.logName,
                "ms": "\(Self.milliseconds(since: run.chunkStarted))",
            ]))
            guard sayAsWritten(chunk: index, failure: reason) else { return }
            if case .unavailable = reason {
                // The model has gone: the rest would fail too.
                sayRestAsWritten()
                return
            }
        }
        transcribeNext()
    }

    /// Gives up on chunk `index` of request `number` once the timeout has passed, if Speak IPA
    /// still waits for it: the request is cancelled, its answer will be dropped, and the rest of
    /// the message is said as written.
    private func timedOut(request number: Int, chunk index: Int) {
        guard var run, run.number == number, run.next == index, run.request != nil else { return }
        Self.log.warning("speak ipa chunk timed out", [
            "request": number,
            "chunk": index,
            "timeoutMs": Int(timeout / .milliseconds(1)),
            "ms": Self.milliseconds(since: run.chunkStarted),
        ])
        run.request?.cancel()
        run.request = nil
        run.deadline = nil
        self.run = run
        guard sayAsWritten(chunk: index, failure: .timedOut) else { return }
        sayRestAsWritten()
    }

    /// Says chunk `index` from `transcribed`, the model's words for it, and keeps them if they
    /// were said as IPA. Returns whether the speech is still going.
    private func say(chunk index: Int, transcribed: [TranscribedWord], cached: Bool) -> Bool {
        guard var run else { return false }
        let chunk = run.chunks[index]
        let speech = SpeakIPAText.speech(of: chunk, transcribed: transcribed, symbols: voiceLoop.kokoroPhonemeSymbols)
        // Counts only: the words and their IPA are the user's. `sayAs` is what is asked of the
        // speech; "chunk not queued" follows if it has ended.
        Self.log.notice("speak ipa chunk transcribed", [
            "request": run.number,
            "chunk": index,
            "chunks": run.chunks.count,
            "words": speech.words,
            "generated": speech.generated,
            "withIPA": speech.wordsWithIPA,
            "unmatched": speech.unmatchedWords,
            "unknownSymbols": speech.unknownSymbolWords,
            "empty": speech.emptyWords,
            "echoed": speech.echoedWords,
            "sayAs": speech.usesIPA ? "ipa" : "written",
            "cached": cached,
            "ms": Self.milliseconds(since: run.chunkStarted),
            "totalMs": Self.milliseconds(since: run.started),
        ])
        guard speech.usesIPA else {
            return sayAsWritten(chunk: index, failure: nil)
        }
        // Counted and kept only once the speech has taken it.
        guard queue(chunk: index, { run.speech.say(speech.parts) }) else { return false }
        run.words += speech.words
        run.wordsWithIPA += speech.wordsWithIPA
        run.next = index + 1
        self.run = run
        if !cached {
            keep(transcribed, for: chunk, of: run.key)
        }
        return true
    }

    /// Says chunk `index` as written, because of `failure`, or because the model's IPA didn't
    /// suit Kokoro when it is nil. Returns whether the speech is still going.
    private func sayAsWritten(chunk index: Int, failure: PronunciationSuggestionError?) -> Bool {
        guard var run else { return false }
        let chunk = run.chunks[index]
        // Counted only once the speech has taken it.
        guard queue(chunk: index, { run.speech.sayAsWritten(chunk) }) else { return false }
        run.words += SpeakIPAText.words(of: chunk).count
        run.writtenChunks += 1
        if run.failure == nil {
            run.failure = failure
        }
        run.next = index + 1
        self.run = run
        return true
    }

    /// Says every chunk still to come as written.
    private func sayRestAsWritten() {
        while let run, run.next < run.chunks.count {
            guard sayAsWritten(chunk: run.next, failure: nil) else { return }
        }
        finishQueueing()
    }

    /// Queues chunk `index` with `say`, which returns whether the speech took it. Returns whether
    /// the speech is still going; once it isn't, `ended(request:end:)` has been or will be told.
    private func queue(chunk index: Int, _ say: () -> Bool) -> Bool {
        guard say() else {
            if let run {
                Self.log.notice("speak ipa chunk not queued; the speech has ended", ["request": run.number, "chunk": index])
            }
            return false
        }
        return true
    }

    /// Every chunk is queued: the speech ends once they have played.
    private func finishQueueing() {
        guard let run else { return }
        Self.log.notice("speak ipa chunks queued", [
            "request": run.number,
            "chunks": run.chunks.count,
            "writtenChunks": run.writtenChunks,
            "ms": Self.milliseconds(since: run.started),
        ])
        run.speech.finish()
    }

    /// Keeps `transcribed` as the IPA of `chunk` in `key`'s message, dropping the message used
    /// longest ago once more than `cachedMessages` are kept.
    private func keep(_ transcribed: [TranscribedWord], for chunk: String, of key: MessageKey) {
        cache[key, default: [:]][chunk] = transcribed
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > Self.cachedMessages {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    // MARK: - Playing

    private func firstSound(request number: Int) {
        guard let run, run.number == number, let current, current.key == run.key else { return }
        Self.log.notice("speak ipa first sound", ["request": number, "ms": Self.milliseconds(since: run.started)])
        self.current = (current.key, .speaking)
    }

    /// The speech of request `number` has ended, as `end` says.
    private func ended(request number: Int, end: IPASpeechEnd) {
        guard let run, run.number == number else { return }
        run.request?.cancel()
        run.deadline?.cancel()
        self.run = nil
        current = nil
        Self.log.notice("speak ipa ended", [
            "request": number,
            "end": end.logName,
            "chunks": run.chunks.count,
            "chunksQueued": run.next,
            "writtenChunks": run.writtenChunks,
            "words": run.words,
            "wordsWithIPA": run.wordsWithIPA,
            "ms": Self.milliseconds(since: run.started),
        ])
        switch end {
        case .finished where run.wordsWithIPA < run.words:
            currentNote = (run.key, Self.note(wordsWithIPA: run.wordsWithIPA, words: run.words, failure: run.failure))
        case .kokoroFailed(let skippedLaterChunks):
            // Not the counts: they are of what was queued, and the system voice said some of it.
            currentNote = (run.key, skippedLaterChunks ? Self.kokoroFailedNote : Self.kokoroFailedOnLastChunkNote)
        case .finished, .stopped:
            break
        }
    }

    private func stop(reason: String) {
        guard let run else { return }
        Self.log.notice("speak ipa stopped", ["request": run.number, "reason": reason, "ms": Self.milliseconds(since: run.started)])
        // Ends the speech, which tells `ended(request:end:)`; then nothing of it is left.
        run.speech.stop()
        if self.run?.number == run.number {
            ended(request: run.number, end: .stopped)
        }
    }

    // MARK: - What Adam is told

    /// How much of a message that played to the end was said as written, and why, if a chunk
    /// failed.
    static func note(wordsWithIPA: Int, words: Int, failure: PronunciationSuggestionError?) -> String {
        var note = "\(wordsWithIPA) of \(words) words were said from Apple Intelligence's IPA; the rest as Kokoro reads them."
        switch failure {
        case nil: break
        case .timedOut: note += " Apple Intelligence didn't answer in time."
        case .declined: note += " The model declined part of the message."
        case .busy: note += " The model was busy."
        case .unavailable: note += " Apple Intelligence stopped being available."
        case .failed: note += " The model failed on part of the message."
        }
        return note
    }

    /// What Adam is told when Kokoro failed partway (`IPASpeechEnd.kokoroFailed`), with later
    /// parts left unsaid.
    static let kokoroFailedNote = "The Kokoro voice stopped partway: the system voice finished the part it was on, and the rest wasn't said."
    /// The same, when Kokoro failed on the last part, which the system voice finished.
    static let kokoroFailedOnLastChunkNote = "The Kokoro voice stopped partway: the system voice said the rest of the message."

    /// Why Speak IPA can't start.
    private enum CantSpeak {
        case voiceModeOn
        case kokoro(SuggestionPlayback)
        case model(PronunciationSuggesterAvailability.UnavailableReason)
        case nothingToSay
        case playbackFailed

        var logName: String {
            switch self {
            case .voiceModeOn: "voiceModeOn"
            case .kokoro(let playback): "kokoro.\(playback)"
            case .model(let reason): "unavailable.\(reason.rawValue)"
            case .nothingToSay: "nothingToSay"
            case .playbackFailed: "playbackFailed"
            }
        }

        var message: String {
            #if os(macOS)
            let settings = "System Settings"
            #else
            let settings = "Settings"
            #endif
            switch self {
            case .voiceModeOn:
                return "Speak IPA plays only while voice mode is off."
            case .kokoro(.needsKokoroVoice), .kokoro(.plays):
                return "Speak IPA needs a Kokoro voice: only Kokoro can say IPA. Choose one in Settings."
            case .kokoro(.needsVoiceModel):
                return "Speak IPA needs a Kokoro voice model. Choose one in Settings."
            case .kokoro(.waitsForVoiceModel):
                return "The Kokoro voice is still loading. Try again once it's ready."
            case .kokoro(.voiceModelFailed):
                return "The Kokoro voice couldn't load. Retry it in Settings."
            case .model(.deviceNotEligible):
                return "Speak IPA needs Apple Intelligence, which this device doesn't support."
            case .model(.appleIntelligenceNotEnabled):
                return "Speak IPA needs Apple Intelligence, which is turned off. Turn it on in \(settings) (search for Apple Intelligence), then try again."
            case .model(.modelNotReady):
                return "Apple Intelligence isn't ready yet: its model may still be downloading, which can take a while on Wi-Fi. Try again later."
            case .model(.other):
                return "Apple Intelligence isn't available right now. Check that it is turned on in \(settings), then try again."
            case .nothingToSay:
                return "This message has nothing Speak IPA can say."
            case .playbackFailed:
                return "Speak IPA couldn't start playing."
            }
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }
}
