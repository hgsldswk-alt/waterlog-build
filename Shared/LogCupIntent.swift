import AppIntents
import Foundation
import WidgetKit

struct LogCupIntent: AppIntent {
    static let title: LocalizedStringResource = "记一杯"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "杯量组标识") var groupID: String
    @Parameter(title: "饮用量") var amount: Int

    init() {}

    init(group: UUID, amount: Int) {
        groupID = group.uuidString
        self.amount = amount
    }

    func perform() async throws -> some IntentResult {
        defer { WidgetCenter.shared.reloadTimelines(ofKind: Launch.widgetKind) }
        guard let group = UUID(uuidString: groupID) else { return .result() }
        let requestID = UUID()
        do {
            try await LogStore().logFromWidget(group: group, amount: amount, now: Date(), zone: .current, requestID: requestID)
        } catch {
            throw WidgetLogError.writeFailed
        }
        return .result()
    }
}

private enum WidgetLogError: LocalizedError {
    case writeFailed

    var errorDescription: String? { L.t("组件记录失败，请打开 App 重试。") }
}
