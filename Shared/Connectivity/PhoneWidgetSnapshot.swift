import Foundation

public struct PhoneWidgetSnapshot: Codable, Sendable {
    public var updatedAt: Date
    public var attackPercent: Int?
    public var defencePercent: Int?
    public var forehandPercent: Int?
    public var backhandPercent: Int?
    public var fastestSmash: Double?
    public var fastestSmashDate: Date?
    public var sessionID: UUID?
    public var shotCount: Int?
    public var activeDuration: Double?
    public init(updatedAt: Date = .now, attackPercent: Int? = nil, defencePercent: Int? = nil,
                forehandPercent: Int? = nil, backhandPercent: Int? = nil, fastestSmash: Double? = nil,
                fastestSmashDate: Date? = nil, sessionID: UUID? = nil,
                shotCount: Int? = nil, activeDuration: Double? = nil) {
        self.updatedAt = updatedAt; self.attackPercent = attackPercent; self.defencePercent = defencePercent
        self.forehandPercent = forehandPercent; self.backhandPercent = backhandPercent
        self.fastestSmash = fastestSmash; self.fastestSmashDate = fastestSmashDate; self.sessionID = sessionID
        self.shotCount = shotCount; self.activeDuration = activeDuration
    }
}
public enum PhoneWidgetSnapshotStore {
    private static let key = "phone-widget-snapshot"
    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.shuttlx.app") ?? .standard }
    public static var speedUnit: String { defaults.string(forKey: "speedUnit") ?? "km/h" }
    public static func setSpeedUnit(_ value: String) { defaults.set(value, forKey: "speedUnit") }
    public static func load() -> PhoneWidgetSnapshot {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(PhoneWidgetSnapshot.self, from: data) else { return .init() }
        return value
    }
    public static func save(_ value: PhoneWidgetSnapshot) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
