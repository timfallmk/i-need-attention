import UIKit

enum Haptics {
    private static let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let notification = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()

    static func prepare() {
        impactHeavy.prepare()
        impactMedium.prepare()
        impactLight.prepare()
        notification.prepare()
        selection.prepare()
    }

    static func press() {
        impactHeavy.impactOccurred(intensity: 1.0)
    }

    static func tick() {
        impactMedium.impactOccurred(intensity: 0.6)
    }

    static func light() {
        impactLight.impactOccurred(intensity: 0.7)
    }

    static func select() {
        selection.selectionChanged()
    }

    static func success() {
        notification.notificationOccurred(.success)
    }

    static func warning() {
        notification.notificationOccurred(.warning)
    }

    static func error() {
        notification.notificationOccurred(.error)
    }
}
