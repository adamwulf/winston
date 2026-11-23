import Foundation
import Testing
import WinstonCore

/// Holding the chat's bottom inset while the app isn't active, so the app switcher's snapshot shows
/// the bottom bar above the keyboard. The insets are the iOS 27.2 simulator's: a 328-point keyboard,
/// reported as 352 points for the snapshot, then gone (34, the home indicator's).
@Suite(.timeLimit(.minutes(1)))
struct BottomInsetHoldTests {
    /// Active, with the keyboard up.
    private func activeWithKeyboard() -> BottomInsetHold {
        var hold = BottomInsetHold()
        hold.sceneIsActive(true)
        hold.measured(328)
        return hold
    }

    @Test func whileActiveNothingIsHeld() {
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

        // Inactive, then the background, where the snapshot's keyboard comes, then none.
        hold.sceneIsActive(false)
        hold.measured(352)
        hold.measured(34)

        #expect(hold.heldInset == 328)
    }

    @Test func becomingActiveLetsGo() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(352)

        // Back in the foreground: the keyboard as it was, then active.
        hold.measured(328)
        hold.sceneIsActive(true)

        #expect(hold.heldInset == nil)
    }

    @Test func theNextTimeItHoldsTheInsetOfThatTime() {
        var hold = activeWithKeyboard()
        hold.sceneIsActive(false)
        hold.measured(352)
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
