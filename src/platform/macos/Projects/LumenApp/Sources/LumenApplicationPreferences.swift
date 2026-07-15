import Combine
import Foundation

@MainActor
final class LumenApplicationPreferences: ObservableObject {
    private enum Key {
        static let hideDockIconWhenMainWindowCloses = "hideDockIconWhenMainWindowCloses"
    }

    @Published private(set) var hidesDockIconWhenMainWindowCloses: Bool

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        hidesDockIconWhenMainWindowCloses = userDefaults.bool(
            forKey: Key.hideDockIconWhenMainWindowCloses
        )
    }

    func setHidesDockIconWhenMainWindowCloses(_ isEnabled: Bool) {
        guard hidesDockIconWhenMainWindowCloses != isEnabled else {
            return
        }
        hidesDockIconWhenMainWindowCloses = isEnabled
        userDefaults.set(isEnabled, forKey: Key.hideDockIconWhenMainWindowCloses)
    }
}
