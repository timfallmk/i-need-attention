import UIKit

enum Haptics {
    private static let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        impactHeavy.prepare()
        impactMedium.prepare()
        notification.prepare()
    }

    static func press() {
        impactHeavy.impactOccurred(intensity: 1.0)
    }

    static func tick() {
        impactMedium.impactOccurred(intensity: 0.6)
    }

    static func success() {
        notification.notificationOccurred(.success)
    }

    static func warning() {
        notification.notificationOccurred(.warning)
    }
}
