import Foundation

/// The chat's bottom inset (the keyboard's space, or the home indicator's) to hold while the app
/// isn't active, so the bottom bar stays where it was.
///
/// Going to the background with the keyboard up, iOS reports the keyboard at another height for the
/// app switcher's snapshot (352 points for a 328-point keyboard in the iOS 27.2 simulator), and the
/// bar moves to match just before the snapshot is taken. The switcher then shows that snapshot under
/// the keyboard as it was on screen, so the bar could end up hidden behind it. Holding the inset the
/// bar had while the app was active keeps the snapshot as the screen looked.
public struct BottomInsetHold: Equatable, Sendable {
    /// The inset to keep, or nil to follow the system's.
    public private(set) var heldInset: CGFloat?
    private var latestInset: CGFloat?
    private var isActive = false

    public init() {}

    /// The bottom inset the system gives the chat now. It doesn't change an inset already held.
    public mutating func measured(_ inset: CGFloat) {
        latestInset = inset
    }

    /// Leaving the active state holds the inset last measured, which is the active one: iOS only
    /// moves the keyboard after that. Becoming active lets go, as the keyboard is back where it was.
    /// Before the scene has been active, such as while it launches, nothing is held.
    public mutating func sceneIsActive(_ active: Bool) {
        if active {
            heldInset = nil
        } else if isActive {
            heldInset = latestInset
        }
        isActive = active
    }
}
