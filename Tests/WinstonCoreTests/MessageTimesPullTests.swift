import Foundation
import Testing
import TelegramLink
import WinstonCore

/// The pull that shows the chat's times on iOS: which drags start it, how far the bubbles slide,
/// and when the times show.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MessageTimesPullTests {
    // MARK: - Which drags are a pull

    @Test func aDragMostlyTowardTheLeadingEdgeIsAPull() {
        #expect(MessageTimesPull.begins(towardLeading: 12, down: 0))
        #expect(MessageTimesPull.begins(towardLeading: 12, down: 11))
        #expect(MessageTimesPull.begins(towardLeading: 12, down: -11))
    }

    @Test func aDragUpDownOrBackIsTheListsToScroll() {
        // Straight down, up, or as far down as across.
        #expect(!MessageTimesPull.begins(towardLeading: 0, down: 12))
        #expect(!MessageTimesPull.begins(towardLeading: 3, down: -12))
        #expect(!MessageTimesPull.begins(towardLeading: 12, down: 12))
        // Toward the trailing edge.
        #expect(!MessageTimesPull.begins(towardLeading: -12, down: 0))
        #expect(!MessageTimesPull.begins(towardLeading: 0, down: 0))
    }

    @Test func leftIsTowardTheLeadingEdgeUnlessTheLayoutIsRightToLeft() {
        #expect(MessageTimesPull.towardLeading(-30, rightToLeft: false) == 30)
        #expect(MessageTimesPull.towardLeading(30, rightToLeft: false) == -30)
        #expect(MessageTimesPull.towardLeading(30, rightToLeft: true) == 30)
        #expect(MessageTimesPull.towardLeading(-30, rightToLeft: true) == -30)
    }

    @Test func theLeadingEdgeIsLeftToTheBackSwipe() {
        #expect(!MessageTimesPull.mayStart(atDistanceFromLeadingEdge: 0))
        #expect(!MessageTimesPull.mayStart(atDistanceFromLeadingEdge: MessageTimesPull.leadingEdgeMargin - 1))
        #expect(MessageTimesPull.mayStart(atDistanceFromLeadingEdge: MessageTimesPull.leadingEdgeMargin))
        #expect(MessageTimesPull.mayStart(atDistanceFromLeadingEdge: 200))
    }

    // MARK: - How far the bubbles slide

    @Test func theBubblesSlideFarEnoughToShowTheWidestTimeBesideThem() {
        #expect(MessageTimesPull.fullyRevealed(widestTime: 50) == 50 + MessageTimesPull.spacing)
        // With no time showing they only stretch.
        #expect(MessageTimesPull.fullyRevealed(widestTime: 0) == 0)
    }

    @Test func theBubblesFollowTheDragUntilTheTimesShowWhole() {
        #expect(MessageTimesPull.slide(forPull: 0, fullyRevealed: 66) == 0)
        #expect(MessageTimesPull.slide(forPull: 30, fullyRevealed: 66) == 30)
        #expect(MessageTimesPull.slide(forPull: 66, fullyRevealed: 66) == 66)
        // Back past where the drag started.
        #expect(MessageTimesPull.slide(forPull: -40, fullyRevealed: 66) == 0)
    }

    @Test func pastThatTheyStretchLessAndLessAndNeverPastTheMostStretch() {
        let fullyRevealed: CGFloat = 66
        let pulls: [CGFloat] = [67, 80, 100, 150, 300, 1000, 100_000]
        let slides = pulls.map { MessageTimesPull.slide(forPull: $0, fullyRevealed: fullyRevealed) }
        for (pull, slide) in zip(pulls, slides) {
            #expect(slide > fullyRevealed && slide < pull)
            #expect(slide < fullyRevealed + MessageTimesPull.maxStretch)
        }
        // Further each time, by less for each point of drag.
        for index in 1..<slides.count {
            #expect(slides[index] > slides[index - 1])
        }
        let firstStep = (slides[1] - slides[0]) / (pulls[1] - pulls[0])
        let laterStep = (slides[3] - slides[2]) / (pulls[3] - pulls[2])
        #expect(laterStep < firstStep && firstStep < 1)
        // No jump where the stretch starts.
        #expect(abs(MessageTimesPull.slide(forPull: 66.01, fullyRevealed: fullyRevealed) - 66) < 0.01)
    }

    @Test func withNoTimeShowingTheBubblesOnlyStretch() {
        let slide = MessageTimesPull.slide(forPull: 40, fullyRevealed: 0)
        #expect(slide > 0 && slide < 40 && slide < MessageTimesPull.maxStretch)
    }

    @Test func reduceMotionSpringsBackWithoutABounce() {
        #expect(MessageTimesPull.releaseBounce(reduceMotion: true) == 0)
        #expect(MessageTimesPull.releaseBounce(reduceMotion: false) > 0)
    }

    // MARK: - A pull

    @Test func theTimesShowFromTheStartOfAPullUntilTheBubblesAreBack() {
        let pull = MessageTimesPull()
        #expect(!pull.showsTimes && pull.slide == 0)
        // UIKit begins the pan some points into the drag: the bubbles follow it from there.
        pull.begin(at: 10)
        #expect(pull.showsTimes && pull.slide == 0)
        pull.timeMeasured(MessageID(1), width: 50)
        pull.move(to: 40)
        #expect(pull.slide == 30)
        let release = pull.release()
        // Back to 0 for the view to animate; the times stay while it does.
        #expect(pull.slide == 0 && pull.showsTimes)
        pull.settled(after: release)
        #expect(!pull.showsTimes)
    }

    @Test func theWidestTimeShowingSetsHowFarTheBubblesSlideBeforeTheyStretch() {
        let pull = MessageTimesPull()
        pull.begin(at: 0)
        pull.timeMeasured(MessageID(1), width: 40)
        pull.timeMeasured(MessageID(2), width: 90)
        pull.move(to: 500)
        let wide = MessageTimesPull.fullyRevealed(widestTime: 90)
        #expect(pull.slide == MessageTimesPull.slide(forPull: 500, fullyRevealed: wide))
        #expect(pull.slide > wide && pull.slide < wide + MessageTimesPull.maxStretch)
        // The wide one's row scrolls away mid-pull: the narrower one sets it now.
        pull.timeHidden(MessageID(2))
        let narrow = MessageTimesPull.fullyRevealed(widestTime: 40)
        #expect(pull.slide == MessageTimesPull.slide(forPull: 500, fullyRevealed: narrow))
        // A time that grows, as when its text changes, counts at its new width.
        pull.timeMeasured(MessageID(1), width: 70)
        #expect(pull.slide == MessageTimesPull.slide(forPull: 500, fullyRevealed: MessageTimesPull.fullyRevealed(widestTime: 70)))
    }

    @Test func aDragBackPastWhereItBeganLeavesTheBubblesInPlace() {
        let pull = MessageTimesPull()
        pull.begin(at: 12)
        pull.timeMeasured(MessageID(1), width: 50)
        pull.move(to: 30)
        #expect(pull.slide == 18)
        pull.move(to: -20)
        #expect(pull.slide == 0 && pull.showsTimes)
    }

    @Test func theNextPullStartsFromTheLastWidestTimeUntilItsOwnAreMeasured() {
        let pull = MessageTimesPull()
        pull.begin(at: 0)
        pull.timeMeasured(MessageID(1), width: 80)
        pull.settled(after: pull.release())
        // The times hide, and each goes away.
        pull.timeHidden(MessageID(1))
        pull.begin(at: 0)
        pull.move(to: 60)
        #expect(pull.slide == 60)
    }

    @Test func aPullDuringTheSpringBackKeepsTheTimesShowing() {
        let pull = MessageTimesPull()
        pull.begin(at: 0)
        pull.timeMeasured(MessageID(1), width: 50)
        pull.move(to: 40)
        let first = pull.release()
        // A new pull before the bubbles are back: the first spring back ends during it.
        pull.begin(at: 0)
        pull.move(to: 20)
        pull.settled(after: first)
        #expect(pull.showsTimes && pull.slide == 20)
        let second = pull.release()
        // The first spring back's end, late, doesn't hide the second's times either.
        pull.settled(after: first)
        #expect(pull.showsTimes)
        pull.settled(after: second)
        #expect(!pull.showsTimes)
    }

    @Test func aTimeMeasuredDuringTheSpringBackLeavesTheBubblesGoingBack() {
        let pull = MessageTimesPull()
        pull.begin(at: 0)
        pull.timeMeasured(MessageID(1), width: 50)
        pull.move(to: 40)
        _ = pull.release()
        pull.timeMeasured(MessageID(2), width: 120)
        pull.timeHidden(MessageID(2))
        pull.move(to: 90)
        #expect(pull.slide == 0)
    }
}
