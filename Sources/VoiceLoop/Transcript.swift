import CoreMedia
import Foundation
import Speech

/// One transcriber result, reduced to what the voice loop needs. Built from a
/// `SpeechTranscriber.Result`, or directly in tests.
package struct TranscriptPiece: Sendable {
    /// Most likely reading, with `audioTimeRange` attributes on its runs.
    package var text: AttributedString
    /// All readings of the same audio, most likely first (may include `text` itself).
    package var alternatives: [AttributedString]
    /// The audio this result covers, on the analyzer's timeline.
    package var range: CMTimeRange
    package var isFinal: Bool

    package init(text: AttributedString, alternatives: [AttributedString], range: CMTimeRange, isFinal: Bool) {
        self.text = text
        self.alternatives = alternatives
        self.range = range
        self.isFinal = isFinal
    }
}

/// The utterance in progress, assembled from transcriber results.
///
/// Final results accumulate. A new result replaces the volatile result its audio overlaps; a
/// volatile result that ends before the new one starts was finalized without being re-sent
/// (the transcriber may do that when finalizing doesn't change it), so it is kept as final.
///
/// Once an utterance is taken or discarded, its audio is *consumed*: later results for that
/// audio (late finals, refined volatiles) are ignored, and results that straddle the boundary
/// keep only the words that start after it. That stops already-sent words from being sent
/// again or merged into the next utterance.
struct Transcript {
    private struct Segment {
        var text: String
        /// Other readings of the same words (see `Utterance.isRereading`), most likely first.
        var alternatives: [String]
        /// The audio the result covers.
        var range: CMTimeRange
    }

    private var finalized: [Segment] = []
    private var volatile: Segment?
    /// Audio before this time belongs to an utterance already taken or discarded.
    private(set) var consumedThrough: CMTime = .zero
    /// End of the latest result applied to this transcript.
    private var heardThrough: CMTime = .zero

    /// The utterance text so far, on one line.
    var text: String {
        Utterance.singleLine((finalized + [volatile].compactMap { $0 }).map(\.text).joined(separator: " "))
    }

    var isEmpty: Bool { text.isEmpty }

    var wordCount: Int { text.split(separator: " ").count }

    /// Adds a result. Returns false, changing nothing, when the result has no words after
    /// the consumed audio.
    mutating func apply(_ piece: TranscriptPiece) -> Bool {
        let text: String
        let alternatives: [String]
        if piece.range.start >= consumedThrough {
            text = String(piece.text.characters)
            alternatives = piece.alternatives.map { String($0.characters) }
        } else {
            text = Self.words(of: piece.text, startingAt: consumedThrough)
            alternatives = piece.alternatives.map { Self.words(of: $0, startingAt: consumedThrough) }
        }
        let line = Utterance.singleLine(text)
        if piece.range.start < consumedThrough && line.isEmpty { return false }

        let segment = Segment(
            text: line,
            alternatives: alternatives
                .map(Utterance.singleLine)
                .filter { Utterance.isRereading($0, of: line) },
            range: piece.range
        )
        if let earlier = volatile, earlier.range.end <= piece.range.start {
            if !earlier.text.isEmpty { finalized.append(earlier) }
            volatile = nil
        }
        if piece.isFinal {
            if !line.isEmpty { finalized.append(segment) }
            volatile = nil
        } else {
            volatile = segment
        }
        heardThrough = max(heardThrough, piece.range.end)
        return true
    }

    /// Returns the utterance so far and clears it, consuming its audio.
    mutating func take() -> Utterance {
        let segments = finalized + [volatile].compactMap { $0 }
        // Each phrase's next-best reading first, then the readings after that.
        var alternatives: [String] = []
        let deepest = segments.map(\.alternatives.count).max() ?? 0
        for rank in 0..<deepest {
            for segment in segments where rank < segment.alternatives.count {
                alternatives.append(segment.alternatives[rank])
            }
        }
        let utterance = Utterance(text: text, alternatives: alternatives)
        discard()
        return utterance
    }

    /// Marks audio before `time` as used without touching the text, so results for it are
    /// ignored from now on.
    mutating func consume(through time: CMTime) {
        consumedThrough = max(consumedThrough, time)
    }

    /// Drops the utterance so far, consuming its audio.
    mutating func discard() {
        finalized = []
        volatile = nil
        consumedThrough = max(consumedThrough, heardThrough)
    }

    /// The part of `text` whose first run starts at or after `time`, judged by the
    /// `audioTimeRange` attributes. Empty when no run qualifies or the timing is missing.
    static func words(of text: AttributedString, startingAt time: CMTime) -> String {
        for run in text.runs {
            if let range = run.audioTimeRange, range.start >= time {
                return String(text[run.range.lowerBound...].characters)
            }
        }
        return ""
    }
}
