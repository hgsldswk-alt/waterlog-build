import Foundation
import UserNotifications

enum ReminderPermission: Equatable {
    case undetermined, denied, allowed
}

protocol ReminderClient {
    func permission() async -> ReminderPermission
    func requestPermission() async throws -> Bool
    func remove(identifier: String) async
    func schedule(identifier: String, hour: Int, minute: Int) async throws
}

struct SystemReminderClient: ReminderClient {
    func permission() async -> ReminderPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .undetermined
        case .authorized, .provisional, .ephemeral: return .allowed
        default: return .denied
        }
    }

    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func remove(identifier: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func schedule(identifier: String, hour: Int, minute: Int) async throws {
        let content = UNMutableNotificationContent()
        content.title = L.t("该喝杯水了")
        content.body = L.t("喝完就点一下，记下这一杯。")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}

struct ReminderService {
    static let identifier = "waterlog.daily"
    let client: any ReminderClient

    func reconcile(_ settings: ReminderSettings, ask: Bool) async throws -> ReminderPermission {
        var permission = await client.permission()
        if settings.enabled && ask && permission == .undetermined {
            permission = try await client.requestPermission() ? .allowed : .denied
        }
        if settings.enabled && permission == .allowed {
            try await client.schedule(identifier: Self.identifier, hour: settings.hour, minute: settings.minute)
        } else {
            await client.remove(identifier: Self.identifier)
        }
        return permission
    }
}
