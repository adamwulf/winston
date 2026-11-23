import Foundation
import Observation
import TelegramLink

/// The pull that shows the chat's times on iOS, as in Messages: dragging the list toward the
/// leading edge slides all the bubbles over together, showing each message's time in a column
/// along the trailing edge, and letting go slides them back and hides the times again.
///
/// The bubbles follow the drag until the widest time showing has room, then stretch: they go on a
/// little further, less and less the further the drag goes. The view tells this where the drag is
/// (`begin(at:)`, `move(to:)`) and how wide each time is, animates `slide` back to 0 on
/// `release()`, and calls `settled(after:)` once the bubbles are back, which hides the times.
///
/// Only `slide` and `showsTimes` are observed, so a drag redraws only what reads them: the one
/// view that slides the bubbles, and the times' slots when they show or hide.
@MainActor @Observable
public final class MessageTimesPull {
    /// How far from the leading edge of the window a drag has to start to be a pull. That edge is
    /// left to the system's back swipe.
    nonisolated public static let leadingEdgeMargin: CGFloat = 24
    /// Between the end of a row and the time beside it: the list's padding, so the times wait just
    /// past the edge of the list, and once the bubbles have slid all the way the widest time ends
    /// where the rows do.
    nonisolated public static let spacing: CGFloat = 16
    /// The most of the list's width a time can take. A longer one wraps, as at the largest text
    /// sizes, so the bubbles never slide more than about this far.
    nonisolated public static let widestTimeFraction: CGFloat = 0.5
    /// The furthest the bubbles stretch past showing the widest time, however far the drag goes.
    nonisolated public static let maxStretch: CGFloat = 60

    /// How far the bubbles have slid toward the leading edge, in points.
    public private(set) var slide: CGFloat = 0
    /// Whether the times show: from the start of a pull until the bubbles are back.
    public private(set) var showsTimes = false

    /// The width of each time showing, by message.
    @ObservationIgnored private var timeWidths: [MessageID: CGFloat] = [:]
    /// The widest of them. Once none show it keeps the last widest, for the start of the next
    /// pull, before that pull's times are measured.
    @ObservationIgnored private var widestTime: CGFloat = 0
    /// Where the drag was, toward the leading edge, when the pull began. Nil between pulls.
    @ObservationIgnored private var start: CGFloat?
    /// How far the drag has gone toward the leading edge since the pull began.
    @ObservationIgnored private var pulled: CGFloat = 0
    /// How many pulls have been let go, so the end of a spring back that a newer pull came after
    /// doesn't hide that pull's times.
    @ObservationIgnored private var releases = 0

    public init() {}

    // MARK: - The drag

    /// `dx`, a movement to the right on screen, as a movement toward the leading edge: left in a
    /// left-to-right layout, right in a right-to-left one.
    nonisolated public static func towardLeading(_ dx: CGFloat, rightToLeft: Bool) -> CGFloat {
        rightToLeft ? dx : -dx
    }

    /// Whether a touch `distance` points from the window's leading edge may start a pull.
    nonisolated public static func mayStart(atDistanceFromLeadingEdge distance: CGFloat) -> Bool {
        distance >= leadingEdgeMargin
    }

    /// Whether a drag that has moved `towardLeading` points toward the leading edge and `down`
    /// points down is a pull: it went toward the leading edge more than up or down. Any other drag
    /// is the list's to scroll.
    nonisolated public static func begins(towardLeading: CGFloat, down: CGFloat) -> Bool {
        towardLeading > 0 && towardLeading > abs(down)
    }

    // MARK: - How far the bubbles slide

    /// How far the bubbles slide to show a time `width` wide whole, `spacing` from its bubble.
    /// With no time showing, 0: the bubbles only stretch.
    nonisolated public static func fullyRevealed(widestTime width: CGFloat) -> CGFloat {
        width > 0 ? width + spacing : 0
    }

    /// How far the bubbles slide for a drag `pull` points toward the leading edge, when sliding
    /// them `fullyRevealed` shows the widest time whole: as far as the drag until then, and past it
    /// a stretch like a scroll view's rubber band, which never goes `maxStretch` further. A drag
    /// back past where it started leaves them where they were.
    nonisolated public static func slide(forPull pull: CGFloat, fullyRevealed: CGFloat) -> CGFloat {
        guard pull > 0 else { return 0 }
        guard pull > fullyRevealed else { return pull }
        let over = pull - fullyRevealed
        // UIScrollView's rubber band: starts at a little over half the drag's speed, then slows.
        return fullyRevealed + (1 - 1 / (over * 0.55 / maxStretch + 1)) * maxStretch
    }

    /// How bouncy the spring back is: a little, or not at all with Reduce Motion on.
    nonisolated public static func releaseBounce(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : 0.2
    }

    // MARK: - A pull

    /// A pull began, with the drag `position` points toward the leading edge. The times show, and
    /// the bubbles follow the drag from here.
    public func begin(at position: CGFloat) {
        start = position
        pulled = 0
        if !showsTimes { showsTimes = true }
        updateSlide()
    }

    /// The drag moved on, to `position` points toward the leading edge.
    public func move(to position: CGFloat) {
        guard let start else { return }
        pulled = position - start
        updateSlide()
    }

    /// The pull was let go, or cancelled: `slide` goes back to 0, which the view animates. The
    /// times show until `settled(after:)` gets the number this returns.
    public func release() -> Int {
        start = nil
        pulled = 0
        releases += 1
        if slide != 0 { slide = 0 }
        return releases
    }

    /// The bubbles are back after the release numbered `release`. The times hide, unless another
    /// pull began since.
    public func settled(after release: Int) {
        guard release == releases, start == nil, showsTimes else { return }
        showsTimes = false
    }

    // MARK: - The times' widths

    /// The time beside message `id` shows `width` points wide, or changed width.
    public func timeMeasured(_ id: MessageID, width: CGFloat) {
        timeWidths[id] = width
        widestTime = timeWidths.values.max() ?? 0
        updateSlide()
    }

    /// The time beside message `id` went away: the times hid, or its row was unloaded.
    public func timeHidden(_ id: MessageID) {
        guard timeWidths.removeValue(forKey: id) != nil, let widest = timeWidths.values.max() else { return }
        widestTime = widest
        updateSlide()
    }

    /// During a pull, slides the bubbles as far as the drag, or the widest time, says. Between
    /// pulls `slide` stays where `release()` put it, so a time measured during the spring back
    /// doesn't cut it short.
    private func updateSlide() {
        guard start != nil else { return }
        let slide = Self.slide(forPull: pulled, fullyRevealed: Self.fullyRevealed(widestTime: widestTime))
        if slide != self.slide { self.slide = slide }
    }
}
