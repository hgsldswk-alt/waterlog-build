import Foundation

enum VolumeUnit: String, CaseIterable, Codable, Identifiable {
    case ml, oz

    var id: Self { self }
    var title: String {
        switch self {
        case .ml: return L.t("毫升（mL）")
        case .oz: return L.t("美制 fl oz")
        }
    }

    var symbol: String {
        switch self {
        case .ml: return L.t("mL")
        case .oz: return L.t("fl oz")
        }
    }

    private var microliters: Decimal {
        switch self {
        case .ml: return 1000
        case .oz: return Decimal(295_735_295_625) / Decimal(10_000_000)
        }
    }

    func number(_ amount: Int, locale: Locale = .current, grouping: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.maximumFractionDigits = self == .ml ? 3 : 2
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(amount) / microliters)) ?? String(amount)
    }

    func label(_ amount: Int) -> String { L.f("%@ %@", number(amount), symbol) }

    func parse(_ text: String, locale: Locale = .current, maxML: Int = 5000) -> Int? {
        let separator = locale.decimalSeparator ?? "."
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: separator)
        guard (1...2).contains(pieces.count), pieces.joined().count <= 15 else { return nil }
        let digits = pieces.map { part in part.compactMap { $0.wholeNumberValue }.filter { (0...9).contains($0) } }
        guard zip(digits, pieces).allSatisfy({ $0.0.count == $0.1.count }),
              digits.contains(where: { !$0.isEmpty }) else { return nil }
        let canonical = digits.map { $0.map(String.init).joined() }.joined(separator: ".")
        guard let number = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var exact = number * microliters
        guard exact >= 1000, exact <= Decimal(maxML * 1000) else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}

enum CupCode {
    static let prefix = "WATER1:"
    static let limits = 1000...5_000_000

    static func valid(_ amounts: [Int]) -> Bool {
        amounts.count == 3 && amounts.allSatisfy(limits.contains)
    }

    static func canonicalML(_ value: Int) -> String {
        let ml = value / 1000
        let fraction = value % 1000
        guard fraction != 0 else { return String(ml) }
        var decimals = String(1000 + fraction).dropFirst()
        while decimals.last == "0" { decimals = decimals.dropLast() }
        return "\(ml).\(decimals)"
    }

    static func encode(_ amounts: [Int]) -> String {
        prefix + amounts.map(canonicalML).joined(separator: "-")
    }

    static func decode(_ text: String) -> [Int]? {
        guard text.utf8.count <= 4096 else { return nil }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(prefix) else { return nil }
        let parts = code.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            let fields = part.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(fields.count), (1...4).contains(fields[0].count),
                  fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  (fields.last?.count ?? 0) <= (fields.count == 1 ? 4 : 3),
                  let ml = Int(fields[0]) else { return nil }
            var ul = ml * 1000
            if fields.count == 2 {
                let fraction = String(fields[1])
                ul += Int(fraction + String(repeating: "0", count: 3 - fraction.count)) ?? 0
            }
            result.append(ul)
        }
        return valid(result) ? result : nil
    }
}
