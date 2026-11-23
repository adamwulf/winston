import Foundation

/// Whether the chat shows its button back to the newest message: once Adam has scrolled up away
/// from the bottom of the list, and not while the list is at it.
///
/// Two distances, so the button doesn't flicker on and off as the list moves about one: it shows
/// once the list is further than `showDistance` from the bottom, hides once it is closer than
/// `hideDistance`, and in between stays as it was. The view tells this which of those the list is
/// in (`Zone`) only as it moves from one to another, not on every scroll.
///
/// A tap hides the button at once (`returnToNewest()`). It stays hidden while the list scrolls
/// back down, through the distances that show it, until the list is at the bottom or Adam scrolls
/// it (`userScrolled()`), as by stopping it on the way.
public struct ScrollToBottomVisibility: Equatable, Sendable {
    /// Further than this from the bottom, in points, the button shows: the newest message, or a
    /// good part of it, is out of sight.
    public static let showDistance: CGFloat = 200
    /// Closer than this the button hides: the newest message is in sight, or nearly. The list's
    /// own padding under it is 16 points, so scrolling to it ends well inside.
    public static let hideDistance: CGFloat = 100

    /// Where the list is, for the button: near the bottom, away from it, or between the two.
    public enum Zone: Equatable, Sendable {
        case nearBottom
        case between
        case awayFromBottom

        /// The zone of a list `distance` points above its bottom.
        public init(distanceFromBottom distance: CGFloat) {
            if distance < ScrollToBottomVisibility.hideDistance {
                self = .nearBottom
            } else if distance > ScrollToBottomVisibility.showDistance {
                self = .awayFromBottom
            } else {
                self = .between
            }
        }
    }

    /// Whether the button shows.
    public private(set) var isShowing = false
    /// The zone the list was last in. A list opens at the bottom.
    private var zone = Zone.nearBottom
    /// Whether the button was tapped and the list hasn't got back to the bottom since, nor been
    /// scrolled by Adam.
    private var isReturning = false

    public init() {}

    /// How far the list is above its bottom, in points, from its scroll geometry: how much further
    /// down it could scroll. `visibleMaxY` is the bottom of what shows, in the content's
    /// coordinates, including what shows under the bottom bar; scrolled all the way down, the
    /// bottom inset (the bar, and the keyboard) is under the end of the content. Below 0 when the
    /// content is shorter than the list.
    public static func distanceFromBottom(contentHeight: CGFloat, bottomInset: CGFloat, visibleMaxY: CGFloat) -> CGFloat {
        contentHeight + bottomInset - visibleMaxY
    }

    /// The list moved into `zone`. Near the bottom the button hides; away from it, it shows,
    /// unless it was tapped and the list is on its way back.
    public mutating func scrolled(into zone: Zone) {
        self.zone = zone
        update()
    }

    /// Adam started scrolling the list. After a tap, this lets the button show again, at once if
    /// the list is away from the bottom.
    public mutating func userScrolled() {
        isReturning = false
        update()
    }

    /// The button was tapped, and the list is scrolling back to the newest message. The button
    /// hides until it is needed again.
    public mutating func returnToNewest() {
        isShowing = false
        isReturning = true
    }

    private mutating func update() {
        switch zone {
        case .nearBottom:
            isShowing = false
            isReturning = false
        case .between:
            break
        case .awayFromBottom:
            if !isReturning {
                isShowing = true
            }
        }
    }
}
