import Foundation

enum L {
    static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: arguments)
    }

    static func daysLogged(_ count: Int) -> String {
        count == 1 ? t("1 天有记录") : f("%@ 天有记录", String(count))
    }
}
