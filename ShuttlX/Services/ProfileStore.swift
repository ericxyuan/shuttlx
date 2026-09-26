import Foundation
import Observation
import SwiftData
import WidgetKit

@Model final class ProfileDocument {
    @Attribute(.unique) var key: String
    @Attribute(.externalStorage) var payload: Data
    init(key: String, payload: Data) { self.key = key; self.payload = payload }
}

@MainActor @Observable final class ProfileStore {
    private(set) var profile = PlayerProfile()
    private(set) var equipment: [UserEquipment] = []
    var speedUnit = "km/h"
    var appearance = "system"
    var showUnknownShots = true
    var errorMessage: String?
    let catalogue = CatalogService()
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var context: ModelContext?

    private struct Snapshot: Codable {
        var profile: PlayerProfile
        var equipment: [UserEquipment]
        var speedUnit: String
        var appearance: String
        var showUnknownShots: Bool
    }

    init() {
        do {
            let configuration = ModelConfiguration("ShuttlXProfile", schema: Schema([ProfileDocument.self]))
            let container = try ModelContainer(for: ProfileDocument.self, configurations: configuration)
            self.container = container
            context = ModelContext(container)
            context?.autosaveEnabled = false
            if let document = try context?.fetch(FetchDescriptor<ProfileDocument>()).first {
                let value = try JSONDecoder().decode(Snapshot.self, from: document.payload)
                profile = value.profile; equipment = value.equipment
                speedUnit = value.speedUnit; appearance = value.appearance; showUnknownShots = value.showUnknownShots
            }
        } catch { errorMessage = "Your profile could not be opened: \(error.localizedDescription)" }
    }

    func updateProfile(_ value: PlayerProfile) throws {
        try persist(profile: value, equipment: equipment)
        profile = value
    }

    func setPhoto(_ data: Data?) throws {
        var next = profile
        next.photoData = data
        try updateProfile(next)
    }

    func addEquipment(_ item: UserEquipment) throws {
        var next = equipment
        // Only one current setup per category; replacement retains dated history.
        for index in next.indices where next[index].category == item.category && next[index].dateRetired == nil {
            guard item.dateStarted >= next[index].dateStarted else {
                throw ProfileError.invalidDate
            }
            next[index].dateRetired = item.dateStarted
        }
        next.append(item)
        try persist(profile: profile, equipment: next)
        equipment = next
    }

    func updateEquipment(_ item: UserEquipment) throws {
        guard item.dateRetired.map({ $0 >= item.dateStarted }) ?? true else { throw ProfileError.invalidDate }
        if item.dateRetired == nil && equipment.contains(where: {
            $0.id != item.id && $0.category == item.category && $0.dateRetired == nil
        }) { throw ProfileError.activeConflict }
        var next = equipment
        guard let index = next.firstIndex(where: { $0.id == item.id }) else { return }
        next[index] = item
        try persist(profile: profile, equipment: next)
        equipment = next
    }

    func currentEquipment(_ category: EquipmentCategory) -> UserEquipment? {
        equipment.first { $0.category == category && $0.dateRetired == nil }
    }

    var currentEquipmentIDs: [UUID] { equipment.filter { $0.dateRetired == nil }.map(\.id) }

    func savePreferences() {
        do {
            try persist(profile: profile, equipment: equipment)
            PhoneWidgetSnapshotStore.setSpeedUnit(speedUnit)
            WidgetCenter.shared.reloadAllTimelines()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func exportProfile() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot(profile: profile, equipment: equipment))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShuttlX-profile.json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private func snapshot(profile: PlayerProfile, equipment: [UserEquipment]) -> Snapshot {
        Snapshot(profile: profile, equipment: equipment, speedUnit: speedUnit, appearance: appearance, showUnknownShots: showUnknownShots)
    }

    private func persist(profile: PlayerProfile, equipment: [UserEquipment]) throws {
        guard let context else { throw ProfileError.unavailable }
        let data = try JSONEncoder().encode(snapshot(profile: profile, equipment: equipment))
        do {
            if let row = try context.fetch(FetchDescriptor<ProfileDocument>()).first { row.payload = data }
            else { context.insert(ProfileDocument(key: "player", payload: data)) }
            try context.save()
        } catch { context.rollback(); throw error }
    }

    enum ProfileError: LocalizedError {
        case unavailable, invalidDate, activeConflict
        var errorDescription: String? {
            switch self {
            case .unavailable: "Profile storage is unavailable. Restart the app before saving changes."
            case .activeConflict: "This category already has current equipment. Retire that setup before making another current."
            case .invalidDate: "The retirement date must follow the start date, and a replacement cannot begin before the current setup."
            }
        }
    }
}
