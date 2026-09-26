import Foundation

public struct WatchWidgetSnapshot: Codable, Sendable {
    public var updatedAt: Date
    public var sessionTime: Double
    public var shotCount: Int
    public var lastShot: String?
    public var lastSwingSpeed: Double?
    public var hasSession: Bool
    public var isActive: Bool
    public init(updatedAt: Date = .now, sessionTime: Double = 0, shotCount: Int = 0,
                lastShot: String? = nil, lastSwingSpeed: Double? = nil, hasSession: Bool = false, isActive: Bool = false) {
        self.updatedAt = updatedAt; self.sessionTime = sessionTime; self.shotCount = shotCount
        self.lastShot = lastShot; self.lastSwingSpeed = lastSwingSpeed
        self.hasSession = hasSession; self.isActive = isActive
    }
}
public enum WatchWidgetSnapshotStore {
    private static let key = "watch-widget-snapshot"
    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.shuttlx.app") ?? .standard }
    public static func load() -> WatchWidgetSnapshot {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(WatchWidgetSnapshot.self, from: data) else { return .init() }
        return value
    }
    public static func save(_ value: WatchWidgetSnapshot) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
