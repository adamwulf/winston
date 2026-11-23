import Foundation
import Testing
import WinstonCore

/// Holding the chat's bottom inset while the app isn't active, so the app switcher's snapshot shows
/// the bottom bar above the keyboard. The insets are the iOS 27.2 simulator's: a 328-point keyboard,
/// reported as 352 points on the way to the background, just before the snapshot, then gone (34,
/// the home indicator's).
@Suite(.timeLimit(.minutes(1)))
struct BottomInsetHoldTests {
    /// Active, with the keyboard up.
    private func activeWithKeyboard() -> BottomInsetHold {
        var hold = BottomInsetHold()
        hold.sceneIsActive(true)
        hold.measured(328)
        return hold
    }

    @Test func whileActiveBeforeLeavingNothingIsHeld() {
        let hold = activeWithKeyboard()

        #expect(hold.heldInset == nil)
    }

    @Test func leavingTheActiveStateHoldsTheInsetItHad() {
        var hold = activeWithKeyboard()

        hold.sceneIsActive(false)

        #expect(hold.heldInset == 328)
    }

    @Test func theKeyboardMovingInTheBackgroundDoesNotMoveTheHold() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)

        // The keyboard reported at 352 points, measured before the background's callback, then none.
        hold.measured(352)
        hold.sceneIsActive(false)
        hold.measured(34)

        #expect(hold.heldInset == 328)
    }

    @Test func becomingActiveWithTheKeyboardBackLetsGo() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(352)

        // Back in the foreground: the keyboard as it was, then active, as in the simulator.
        hold.measured(328)
        hold.sceneIsActive(true)

        #expect(hold.heldInset == nil)
        #expect(!hold.isWaitingToLetGo)
    }

    /// Active before the keyboard is back: the order inferred from the bar dropping behind the
    /// keyboard for a moment on an iPhone, when the hold let go as the app became active.
    @Test func becomingActiveBeforeTheKeyboardIsBackKeepsHolding() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(352)
        hold.measured(34)

        hold.sceneIsActive(true)

        #expect(hold.heldInset == 328)
        #expect(hold.isWaitingToLetGo)
    }

    @Test func theKeyboardComingBackAfterActiveLetsGo() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(34)
        hold.sceneIsActive(true)

        hold.measured(328)

        #expect(hold.heldInset == nil)
        #expect(!hold.isWaitingToLetGo)
    }

    @Test func anotherInsetAfterActiveKeepsWaitingForTheHeldOne() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(34)
        hold.sceneIsActive(true)

        hold.measured(352)

        #expect(hold.heldInset == 328)
        #expect(hold.isWaitingToLetGo)

        hold.measured(328)

        #expect(hold.heldInset == nil)
    }

    @Test func anInsetWithinAPointOfTheHeldOneIsBack() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(34)
        hold.sceneIsActive(true)

        hold.measured(328.4)

        #expect(hold.heldInset == nil)
    }

    @Test func letGoWhileWaitingLetsGo() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(34)
        hold.sceneIsActive(true)

        // The keyboard isn't coming back.
        hold.letGo()

        #expect(hold.heldInset == nil)
        #expect(!hold.isWaitingToLetGo)
    }

    @Test func letGoWhileNotActiveDoesNothing() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(34)

        hold.letGo()

        #expect(hold.heldInset == 328)
    }

    @Test func leavingAgainBeforeTheKeyboardIsBackKeepsTheFirstHold() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(34)
        hold.sceneIsActive(true)

        hold.sceneIsActive(false)

        #expect(hold.heldInset == 328)
        #expect(!hold.isWaitingToLetGo)
    }

    @Test func theKeyboardBackBeforeActiveIsHeldTheNextTime() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(352)
        hold.measured(34)
        // Back in the foreground: the keyboard as it was before active, then no change.
        hold.measured(328)
        hold.sceneIsActive(true)

        hold.sceneIsActive(false)

        #expect(hold.heldInset == 328)
    }

    @Test func theNextTimeItHoldsTheInsetOfThatTime() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(352)
        hold.measured(328)
        hold.sceneIsActive(true)
        // The keyboard closed.
        hold.measured(34)

        hold.sceneIsActive(false)

        #expect(hold.heldInset == 34)
    }

    @Test func beforeTheSceneHasBeenActiveNothingIsHeld() {
        var hold = BottomInsetHold()
        // As at launch, before the layout is done.
        hold.measured(0)

        hold.sceneIsActive(false)

        #expect(hold.heldInset == nil)
    }

    @Test func withNoInsetMeasuredNothingIsHeld() {
        var hold = BottomInsetHold()
        hold.sceneIsActive(true)

        hold.sceneIsActive(false)

        #expect(hold.heldInset == nil)
    }
}
