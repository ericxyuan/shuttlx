import Foundation

enum EquipmentCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case racket, shoes, strings, grip
    var id: String { rawValue }
    var title: String { switch self { case .racket: "Primary Racket"; case .shoes: "Shoes"; case .strings: "Strings"; case .grip: "Grip" } }
    var symbol: String { switch self { case .racket: "tennis.racket"; case .shoes: "shoe.2"; case .strings: "line.3.crossed.swirl.circle"; case .grip: "hand.closed" } }
}

struct EquipmentBrand: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var website: URL
}

struct EquipmentProduct: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var brandID: String
    var category: EquipmentCategory
    var modelName: String
    var generation: String?
    var releaseYear: Int?
    var discontinued: Bool?
    var description: String
    var sourceURL: URL
    var verifiedAt: Date
}

struct EquipmentVariant: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var productID: String
    var label: String
    var weightClass: String?
    var gripSize: String?
    var shoeSizeRange: String?
    var stringGauge: Double?
    var gripThickness: Double?
    var region: String?
    var sourceURL: URL
}

struct EquipmentColorway: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var productID: String
    var officialName: String
    var primaryColor: String?
    var secondaryColor: String?
    var releaseYear: Int?
    var sourceURL: URL
}

struct EquipmentImage: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var productID: String
    var colorwayID: String?
    var url: URL
    var sourceURL: URL
    /// A catalogue importer is responsible for recording permission, not just attribution.
    var permission: String
    var altText: String
}

struct EquipmentCatalogue: Codable, Sendable {
    var schemaVersion: Int
    var title: String
    var isDevelopmentDataset: Bool
    var brands: [EquipmentBrand]
    var products: [EquipmentProduct]
    var variants: [EquipmentVariant]
    var colorways: [EquipmentColorway]
    var images: [EquipmentImage]
    static let empty = EquipmentCatalogue(schemaVersion: 1, title: "Equipment catalogue", isDevelopmentDataset: true, brands: [], products: [], variants: [], colorways: [], images: [])
}

struct UserEquipment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var productID: String
    var variantID: String?
    var colorwayID: String?
    var category: EquipmentCategory
    /// Snapshot preserves readable history if a catalogue record is later removed.
    var manufacturer: String
    var modelName: String
    var variantLabel: String?
    var colorwayName: String?
    var shoeSize: String?
    var mainTensionLB: Double?
    var crossTensionLB: Double?
    var notes = ""
    var dateStarted: Date
    var dateRetired: Date?
}

struct PlayerProfile: Codable, Equatable, Sendable {
    var name = ""
    var country = ""
    var heightCM: Double?
    var weightKG: Double?
    var discipline = "Multiple"
    var style = ""
    var photoData: Data?
}
