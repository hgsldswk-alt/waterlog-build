import Foundation

struct Entitlement: Codable, Equatable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false
    var purchaseDate: Date?
    var purchaseRevoked = false

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(localStart, trialClaimedAt ?? localStart)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    mutating func startPaidPeriod(at now: Date, free: Bool) {
        if !free && proStartedAt == nil { proStartedAt = now }
    }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }

    func widgetCanLog(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || (proStartedAt != nil && hasPro(at: now, free: false))
    }

    mutating func apply(_ purchase: VerifiedPurchase) {
        switch purchase.kind {
        case .trial:
            if !purchase.revoked {
                trialClaimedAt = min(trialClaimedAt ?? purchase.originalDate, purchase.originalDate)
            }
        case .pro:
            if let purchaseDate, purchase.date < purchaseDate ||
                (purchase.date == purchaseDate && purchaseRevoked && !purchase.revoked) { return }
            purchaseDate = purchase.date
            purchaseRevoked = purchase.revoked
            purchasedPro = !purchase.revoked
        }
    }
}

struct VerifiedPurchase {
    enum Kind { case pro, trial }
    var kind: Kind
    var date: Date
    var originalDate: Date
    var revoked: Bool
}
