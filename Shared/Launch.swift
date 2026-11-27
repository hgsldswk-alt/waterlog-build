import Foundation

enum Launch {
    static let freePeriod = false
    static let appGroup = "group.com.hgsldswk.waterlog"
    static let widgetKind = "WaterLogWidget"
    static let proID = "com.hgsldswk.waterlog.pro"
    static let trialID = "com.hgsldswk.waterlog.trial"
    static let homeURL = URL(string: "waterlog://today")!

    static func isFree(arguments: [String]) -> Bool {
        freePeriod && !arguments.contains { ["-paid-mode", "-paywall", "-expired"].contains($0) }
    }

    static var isFree: Bool { isFree(arguments: ProcessInfo.processInfo.arguments) }

    static func storeURL(id: String) -> URL? {
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)")
    }
}
