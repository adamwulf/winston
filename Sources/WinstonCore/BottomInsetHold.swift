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

    /// Leaving the active state holds the inset last measured, until the scene is active again and
    /// the system's inset is followed again. Going on from inactive to the background keeps the
    /// inset already held. Before the scene has been active, such as while it launches, nothing is
    /// held.
    public mutating func sceneIsActive(_ active: Bool) {
        if active {
            heldInset = nil
        } else if isActive {
            heldInset = latestInset
        }
        isActive = active
    }
}
