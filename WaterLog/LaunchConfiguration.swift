import Foundation

struct LaunchConfiguration {
    let arguments: [String]
    let environment: [String: String]
    let uiTesting: Bool

    init(process: ProcessInfo = .processInfo) {
        arguments = process.arguments
        environment = process.environment
        #if DEBUG
        uiTesting = arguments.contains("-ui-testing")
        #else
        uiTesting = false
        #endif
    }

    func enabled(_ flag: String) -> Bool { uiTesting && arguments.contains(flag) }
    var free: Bool { Launch.isFree(arguments: uiTesting ? arguments : []) }
    var demo: Bool { enabled("-demo") }
    var now: Date { demo ? Date(timeIntervalSince1970: 1_795_081_260) : Date() }
    var zone: TimeZone { demo ? .gmt : .current }

    var sampleEntries: [DrinkEntry]? {
        guard demo else { return nil }
        let offsets: [(Int, Int, Int, Drink)] = enabled("-milestone")
            ? (-6 ... -1).map { ($0, 7, 40, .water) } : [
            (0, 8, 25, .tea), (0, 7, 40, .water),
            (-1, 10, 15, .water), (-3, 11, 20, .water),
            (-5, 8, 30, .water), (-6, 8, 45, .water)
        ]
        let calendar = Days.calendar(in: zone)
        return offsets.compactMap { day, hour, minute, drink in
            guard let date = calendar.date(byAdding: .day, value: day, to: now),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) else { return nil }
            let volume = day == 0 && drink == .water ? 500_000 : 250_000
            return DrinkEntry(volume: volume, drink: drink, date: time, zone: zone, now: time)
        }
    }

    var store: LogStore {
        if uiTesting {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("WaterLogUITests.sqlite")
            return LogStore(url: path)
        }
        return LogStore()
    }

    var storeURL: URL? {
        if uiTesting, let id = environment["WATERLOG_TEST_STORE_ID"] { return Launch.storeURL(id: id) }
        let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? ""
        return Launch.storeURL(id: id) ?? (enabled("-store-shots") ? Launch.storeURL(id: "1234567890") : nil)
    }
}

struct TestReminderClient: ReminderClient {
    let result: ReminderPermission

    func permission() async -> ReminderPermission { result }
    func requestPermission() async throws -> Bool { result == .allowed }
    func remove(identifier: String) async {}
    func schedule(identifier: String, hour: Int, minute: Int) async throws {}
}
