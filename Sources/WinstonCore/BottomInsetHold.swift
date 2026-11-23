import Foundation

/// The chat's bottom inset (the keyboard's space, or the home indicator's) to hold while the app
/// isn't active, so the bottom bar stays where it was.
///
/// In the iOS 27.2 simulator, going to the background with the keyboard up, UIKit reports the
/// keyboard at another height (352 points for a 328-point keyboard) just before it takes the app
/// switcher's snapshot, and the bar moves to match: the switcher shows it out of place. On an
/// iPhone the switcher showed the bar hidden behind the keyboard, most likely for the same reason
/// with a shorter height reported. Holding the inset the bar had while the app was active keeps it
/// where it was on screen.
///
/// The keyboard goes in the background, and comes back on the way to the foreground. In the
/// simulator it is back before the app is active; on an iPhone, letting go as the app became active
/// dropped the bar behind the keyboard for a moment, so it evidently comes back just after there.
/// The hold lets go once the system's inset is back to the one held, or when told to (`letGo()`),
/// in case the keyboard doesn't come back.
public struct BottomInsetHold: Equatable, Sendable {
    /// The inset to keep, or nil to follow the system's.
    public private(set) var heldInset: CGFloat?
    /// The system's inset, as last measured.
    public private(set) var latestInset: CGFloat?
    private var isActive = false

    public init() {}

    /// Whether the scene is active but the system's inset isn't back to the one held yet.
    public var isWaitingToLetGo: Bool {
        isActive && heldInset != nil
    }

    /// The bottom inset the system gives the chat now. It doesn't change an inset already held, but
    /// once the scene is active, getting back to it lets go.
    public mutating func measured(_ inset: CGFloat) {
        latestInset = inset
        if isActive {
            letGoIfCaughtUp()
        }
    }

    /// Leaving the active state holds the inset last measured. Becoming active lets go if the
    /// system's inset is already back to it, and otherwise waits for it. Going on from inactive to
    /// the background, or leaving the active state again while waiting, keeps the inset already
    /// held. Before the scene has been active, such as while it launches, nothing is held.
    public mutating func sceneIsActive(_ active: Bool) {
        if active {
            isActive = true
            letGoIfCaughtUp()
        } else {
            if isActive, heldInset == nil {
                heldInset = latestInset
            }
            isActive = false
        }
    }

    /// Lets go while waiting, as when the keyboard isn't coming back. Nothing while not active.
    public mutating func letGo() {
        if isActive {
            heldInset = nil
        }
    }

    private mutating func letGoIfCaughtUp() {
        guard let held = heldInset, let latestInset else { return }
        // Within a point: the same inset, measured again.
        if abs(latestInset - held) < 1 {
            heldInset = nil
        }
    }
}
