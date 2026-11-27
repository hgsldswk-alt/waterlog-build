import Foundation
import CoreImage
import UIKit
import XCTest

final class CoreTests: XCTestCase {
    func testVolumeConversionLocaleAndCodeRoundTrip() {
        let en = Locale(identifier: "en_US")
        let comma = Locale(identifier: "de_DE")
        XCTAssertEqual(VolumeUnit.ml.parse("150.125", locale: en), 150_125)
        XCTAssertEqual(VolumeUnit.ml.parse("150,125", locale: comma), 150_125)
        XCTAssertNil(VolumeUnit.ml.parse("150,125", locale: en))
        XCTAssertEqual(VolumeUnit.oz.parse("1", locale: en), 29_574)
        XCTAssertEqual(VolumeUnit.oz.number(250_000, locale: en), "8.45")
        XCTAssertEqual(VolumeUnit.oz.number(250_000, locale: comma), "8,45")
        XCTAssertNil(VolumeUnit.ml.parse("0.999", locale: en))
        XCTAssertNil(VolumeUnit.ml.parse("5000.001", locale: en))
        XCTAssertEqual(VolumeUnit.ml.parse("20000", locale: en, maxML: 20_000), 20_000_000)

        let values = [1001, 250_125, 5_000_000]
        XCTAssertEqual(CupCode.encode(values), "WATER1:1.001-250.125-5000")
        XCTAssertEqual(CupCode.decode("\n" + CupCode.encode(values) + "\n"), values)
        for invalid in ["WATER2:150-250-500", "WATER1:150-250", "WATER1:0-250-500", "WATER1:150-250-5000.001",
                        "WATER1:150-2.0001-500", "WATER1:150-2e2-500", "WATER1:150-250-500\ncomment"] {
            XCTAssertNil(CupCode.decode(invalid), invalid)
        }
    }

    func testDailyKeysAcrossDSTAndSevenDaysAcrossNewYear() throws {
        let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let missing = try instant("2026-03-08T09:59:00Z")
        let springForward = try instant("2026-03-08T10:00:00Z")
        XCTAssertEqual(Days.key(missing, in: pacific), "2026-03-08")
        XCTAssertEqual(Days.key(springForward, in: pacific), "2026-03-08")
        let repeatedHours = try ["2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z"].map(instant)
        XCTAssertEqual(repeatedHours.map { Days.key($0, in: pacific) }, ["2026-11-01", "2026-11-01"])
        let midnight = try instant("2026-03-09T07:00:00Z")
        XCTAssertEqual(Days.nextMidnight(after: missing, in: pacific), midnight)

        let january = try instant("2027-01-03T14:00:00Z")
        let keys = Days.week(ending: january, in: pacific).map { Days.key($0, in: pacific) }
        XCTAssertEqual(keys, ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31",
                              "2027-01-01", "2027-01-02", "2027-01-03"])
    }

    func testPaidUpgradeTrialReceiptRestorationAndRevocation() throws {
        let first = try instant("2026-01-01T00:00:00Z")
        let paid = try instant("2026-03-01T00:00:00Z")
        var old = Entitlement(firstOpen: first)
        old.startPaidPeriod(at: first, free: true)
        XCTAssertNil(old.proStartedAt)
        XCTAssertTrue(old.hasPro(at: paid, free: true))
        old.startPaidPeriod(at: paid, free: false)
        let expires = paid.addingTimeInterval(30 * 86_400)
        XCTAssertTrue(old.hasPro(at: expires.addingTimeInterval(-1), free: false))
        XCTAssertFalse(old.hasPro(at: expires, free: false))

        let claimDate = paid.addingTimeInterval(7200)
        let trial = VerifiedPurchase(kind: .trial, date: claimDate, originalDate: claimDate, revoked: false)
        old.apply(trial)
        XCTAssertEqual(old.trialEnd, expires)
        var reinstall = Entitlement(firstOpen: expires)
        reinstall.startPaidPeriod(at: expires, free: false)
        reinstall.apply(trial)
        XCTAssertEqual(reinstall.trialStart, claimDate)
        XCTAssertFalse(reinstall.hasPro(at: expires.addingTimeInterval(7200), free: false))

        var purchase = VerifiedPurchase(kind: .pro, date: expires, originalDate: expires, revoked: false)
        old.apply(purchase)
        XCTAssertTrue(old.hasPro(at: expires.addingTimeInterval(86_400), free: false))
        purchase.revoked = true
        old.apply(purchase)
        XCTAssertFalse(old.hasPro(at: expires.addingTimeInterval(86_400), free: false))
        purchase.revoked = false
        old.apply(purchase)
        XCTAssertFalse(old.purchasedPro)
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testMilestoneAndReviewEligibility() throws {
        var preferences = Preferences()
        let now = try instant("2026-11-19T12:00:00Z")
        preferences.usageDays = ["2026-11-01", "2026-11-02", "2026-11-03"]
        XCTAssertFalse(preferences.evaluateMilestone(recordedDays: 6))
        XCTAssertTrue(preferences.evaluateMilestone(recordedDays: 7))
        XCTAssertEqual(preferences.pendingMilestone, 7)
        XCTAssertFalse(preferences.mayRequestReview(at: now, recordedDays: 7, blocked: false))
        preferences.pendingMilestone = nil
        XCTAssertFalse(preferences.evaluateMilestone(recordedDays: 8))
        XCTAssertTrue(preferences.mayRequestReview(at: now, recordedDays: 8, blocked: false))
        XCTAssertFalse(preferences.mayRequestReview(at: now, recordedDays: 8, blocked: true))
        preferences.lastReview = now
        XCTAssertFalse(preferences.mayRequestReview(at: now.addingTimeInterval(119 * 86_400), recordedDays: 9, blocked: false))
        XCTAssertTrue(preferences.mayRequestReview(at: now.addingTimeInterval(120 * 86_400), recordedDays: 9, blocked: false))
        XCTAssertTrue(preferences.evaluateMilestone(recordedDays: 30))
        XCTAssertEqual(preferences.pendingMilestone, 30)
    }

    @MainActor
    func testSharePNGCIDetectorDecodesAppStoreURLAndVolumeDoesNotAffectCard() async throws {
        let now = try instant("2026-11-19T12:00:00Z")
        let timer = Days.week(ending: now, in: .gmt)
        func card(total: Int) -> CardContent {
            let week = timer.enumerated().map { index, date in
                WeekDay(id: Days.key(date, in: .gmt), date: date, total: total * index, recorded: index < 5)
            }
            return CardContent(week: week, zone: .gmt, milestone: nil, locale: Locale(identifier: "en_US"))
        }
        let visible = card(total: 111_111)
        let differentVolumes = card(total: 999_999)
        XCTAssertEqual(visible.days, differentVolumes.days)
        XCTAssertEqual(visible.caption, differentVolumes.caption)
        XCTAssertEqual(visible.count, 5)
        XCTAssertEqual(visible.days.map(\.shortName), ["Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"])
        XCTAssertNil(Launch.storeURL(id: ""))
        let url = try XCTUnwrap(Launch.storeURL(id: "1234567890"))
        let png = try XCTUnwrap(CardArtwork.png(content: visible, url: url))
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1440)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: context,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(messages, [url.absoluteString])
    }

    private func instant(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }
}
