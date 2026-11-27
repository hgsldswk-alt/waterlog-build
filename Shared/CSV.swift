import Foundation

enum CSV {
    static func export(_ days: [DayLog]) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rows = ["id,local_date,consumed_at_utc,time_zone,drink,volume_ml"]
        for day in days {
            for entry in day.entries {
                rows.append([
                    entry.id.uuidString, entry.day, iso.string(from: entry.consumedAt),
                    entry.zoneID, entry.drink.rawValue, CupCode.canonicalML(entry.volume)
                ].joined(separator: ","))
            }
        }
        return Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
