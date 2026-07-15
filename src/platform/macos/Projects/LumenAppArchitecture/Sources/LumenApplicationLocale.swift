import Foundation

@frozen public enum LumenApplicationLocale: String, CaseIterable, Sendable {
    case english = "en"
    case korean = "ko"
    case japanese = "ja"

    public var nativeTitle: String {
        switch self {
        case .english: "English"
        case .korean: "한국어"
        case .japanese: "日本語"
        }
    }

    public static func resolve(_ identifier: String?) -> Self {
        guard let language = identifier?
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first else {
            return .english
        }
        return Self(rawValue: String(language)) ?? .english
    }
}

@MainActor
public final class LumenApplicationLocaleStore {
    public typealias ActiveLanguage = @MainActor () -> String?

    private static let appleLanguagesKey = "AppleLanguages"

    private let userDefaults: UserDefaults
    private let activeLanguage: ActiveLanguage

    public init(
        userDefaults: UserDefaults,
        activeLanguage: @escaping ActiveLanguage
    ) {
        self.userDefaults = userDefaults
        self.activeLanguage = activeLanguage
    }

    public var activeLocale: LumenApplicationLocale {
        LumenApplicationLocale.resolve(activeLanguage())
    }

    @discardableResult
    public func select(_ locale: LumenApplicationLocale) -> Bool {
        let selectedLanguages = userDefaults.stringArray(forKey: Self.appleLanguagesKey)
        if selectedLanguages != [locale.rawValue] {
            userDefaults.set([locale.rawValue], forKey: Self.appleLanguagesKey)
        }
        return activeLocale != locale
    }
}
