import XCTest

final class ReminderTests: XCTestCase {
    func testDenialAndReplacementAndDisable() async throws {
        let denied = ReminderSpy(allowRequest: false)
        let deniedService = ReminderService(client: denied)
        var settings = ReminderSettings(enabled: true, hour: 15, minute: 30)
        let outcome = try await deniedService.reconcile(settings, ask: true)
        XCTAssertEqual(outcome, .denied)
        let deniedRequest = await denied.requested
        let deniedPending = await denied.pending
        XCTAssertEqual(deniedRequest, 1)
        XCTAssertTrue(deniedPending.isEmpty)

        let allowed = ReminderSpy(allowRequest: true)
        let service = ReminderService(client: allowed)
        _ = try await service.reconcile(settings, ask: true)
        settings.hour = 18
        settings.minute = 5
        _ = try await service.reconcile(settings, ask: false)
        let updated = await allowed.pending
        XCTAssertEqual(updated, [ReminderService.identifier: "18:5"])
        settings.enabled = false
        _ = try await service.reconcile(settings, ask: false)
        let remaining = await allowed.pending
        XCTAssertTrue(remaining.isEmpty)
    }
}

private actor ReminderSpy: ReminderClient {
    private var status = ReminderPermission.undetermined
    private let allowRequest: Bool
    private(set) var requested = 0
    private(set) var pending: [String: String] = [:]

    init(allowRequest: Bool) { self.allowRequest = allowRequest }

    func permission() async -> ReminderPermission { status }
    func requestPermission() async throws -> Bool {
        requested += 1
        status = allowRequest ? .allowed : .denied
        return allowRequest
    }
    func remove(identifier: String) async { pending[identifier] = nil }
    func schedule(identifier: String, hour: Int, minute: Int) async throws { pending[identifier] = "\(hour):\(minute)" }
}
