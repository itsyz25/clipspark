import UIKit

/// Haptic feedback: a tick on snap / cut / playhead settle, per spec.
public enum CSHaptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let notify = UINotificationFeedbackGenerator()

    public static func tick() { selection.selectionChanged() }
    public static func cut()  { impact.impactOccurred(intensity: 0.8) }
    public static func snap() { impact.impactOccurred(intensity: 0.5) }
    public static func done() { notify.notificationOccurred(.success) }
}
