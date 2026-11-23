import Foundation
import Testing
import WinstonCore

/// The button back to the newest message: shown once the list is scrolled up away from the bottom,
/// hidden near it, and hidden at once by a tap.
@Suite(.timeLimit(.minutes(1)))
struct ScrollToBottomVisibilityTests {
    typealias Zone = ScrollToBottomVisibility.Zone

    /// Scrolled up, with the button showing.
    private func scrolledUp() -> ScrollToBottomVisibility {
        var visibility = ScrollToBottomVisibility()
        visibility.scrolled(into: .between)
        visibility.scrolled(into: .awayFromBottom)
        return visibility
    }

    // MARK: - Distances

    // The iOS 27.2 simulator's iPhone 17e at launch: 5,000 points of messages, under a 101-point
    // navigation bar and over a 108-point bottom bar, in an 844-point screen. The list shows the
    // content under both bars too, so scrolled all the way down it shows to 5,108.

    @Test func atTheBottomTheDistanceIsZero() {
        let distance = ScrollToBottomVisibility.distanceFromBottom(contentHeight: 5000, bottomInset: 108, visibleMaxY: 5108)

        #expect(distance == 0)
    }

    @Test func scrolledUpTheDistanceIsHowFarItCouldStillScrollDown() {
        let distance = ScrollToBottomVisibility.distanceFromBottom(contentHeight: 5000, bottomInset: 108, visibleMaxY: 4600)

        #expect(distance == 508)
    }

    @Test func theKeyboardIsPartOfTheBottomInset() {
        // A 300-point keyboard under the bar, before the list scrolls to keep up.
        let distance = ScrollToBottomVisibility.distanceFromBottom(contentHeight: 5000, bottomInset: 408, visibleMaxY: 5108)

        #expect(distance == 300)
    }

    @Test func aShortChatIsAtTheBottom() {
        // Two messages, shorter than the list, which shows them from the top.
        let distance = ScrollToBottomVisibility.distanceFromBottom(contentHeight: 200, bottomInset: 108, visibleMaxY: 743)

        #expect(Zone(distanceFromBottom: distance) == .nearBottom)
    }

    @Test(arguments: [
        (CGFloat(-20), Zone.nearBottom),
        (0, .nearBottom),
        (100, .nearBottom),
        (101, .between),
        (150, .between),
        (200, .between),
        (201, .awayFromBottom),
        (5000, .awayFromBottom),
    ])
    func zones(distance: CGFloat, zone: Zone) {
        #expect(Zone(distanceFromBottom: distance) == zone)
    }

    // MARK: - Showing and hiding

    @Test func aListAtTheBottomShowsNoButton() {
        let visibility = ScrollToBottomVisibility()

        #expect(!visibility.isShowing)
    }

    @Test func scrollingAwayFromTheBottomShowsTheButton() {
        var visibility = ScrollToBottomVisibility()

        visibility.scrolled(into: .between)
        #expect(!visibility.isShowing)

        visibility.scrolled(into: .awayFromBottom)
        #expect(visibility.isShowing)
    }

    @Test func comingBackPartWayKeepsTheButton() {
        var visibility = scrolledUp()

        visibility.scrolled(into: .between)

        #expect(visibility.isShowing)
    }

    @Test func comingBackNearTheBottomHidesTheButton() {
        var visibility = scrolledUp()

        visibility.scrolled(into: .between)
        visibility.scrolled(into: .nearBottom)

        #expect(!visibility.isShowing)
    }

    @Test func goingBackAndForthBetweenTheDistancesDoesNotShowTheButton() {
        var visibility = ScrollToBottomVisibility()

        for _ in 0..<3 {
            visibility.scrolled(into: .between)
            visibility.scrolled(into: .nearBottom)
        }

        #expect(!visibility.isShowing)
    }

    @Test func goingBackAndForthBetweenTheDistancesKeepsAButtonShowing() {
        var visibility = scrolledUp()

        for _ in 0..<3 {
            visibility.scrolled(into: .between)
            visibility.scrolled(into: .awayFromBottom)
        }

        #expect(visibility.isShowing)
    }

    // MARK: - A tap

    @Test func aTapHidesTheButtonAtOnce() {
        var visibility = scrolledUp()

        visibility.returnToNewest()

        #expect(!visibility.isShowing)
    }

    @Test func theButtonStaysHiddenWhileTheListScrollsBack() {
        var visibility = scrolledUp()
        visibility.returnToNewest()

        // The scroll back passes through the distances that show the button.
        visibility.scrolled(into: .awayFromBottom)
        #expect(!visibility.isShowing)

        visibility.scrolled(into: .between)
        #expect(!visibility.isShowing)

        visibility.scrolled(into: .nearBottom)
        #expect(!visibility.isShowing)
    }

    @Test func onceBackAtTheBottomScrollingUpShowsTheButtonAgain() {
        var visibility = scrolledUp()
        visibility.returnToNewest()
        visibility.scrolled(into: .between)
        visibility.scrolled(into: .nearBottom)

        visibility.userScrolled()
        visibility.scrolled(into: .between)
        visibility.scrolled(into: .awayFromBottom)

        #expect(visibility.isShowing)
    }

    /// Getting to the bottom ends the return even with no scroll of Adam's reported after it, as
    /// for a scroll from the Mac's keyboard.
    @Test func comingBackNearTheBottomEndsTheReturn() {
        var visibility = scrolledUp()
        visibility.returnToNewest()
        visibility.scrolled(into: .nearBottom)

        visibility.scrolled(into: .awayFromBottom)

        #expect(visibility.isShowing)
    }

    @Test func scrollingDuringTheReturnWhileAwayShowsTheButtonAtOnce() {
        var visibility = scrolledUp()
        visibility.returnToNewest()
        visibility.scrolled(into: .awayFromBottom)

        // Adam stops the scroll back on the way, still far from the bottom.
        visibility.userScrolled()

        #expect(visibility.isShowing)
    }

    @Test func scrollingDuringTheReturnBetweenTheDistancesWaitsUntilAwayAgain() {
        var visibility = scrolledUp()
        visibility.returnToNewest()
        visibility.scrolled(into: .between)

        visibility.userScrolled()
        #expect(!visibility.isShowing)

        visibility.scrolled(into: .awayFromBottom)
        #expect(visibility.isShowing)
    }

    @Test func scrollingNearTheBottomShowsNoButton() {
        var visibility = ScrollToBottomVisibility()

        visibility.userScrolled()

        #expect(!visibility.isShowing)
    }
}
