import Foundation
import Observation

@MainActor @Observable final class CatalogService {
    private(set) var catalogue = EquipmentCatalogue.empty
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    init() { load() }

    var importedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShuttlX/catalogue-imported.json")
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let bundledURL = Bundle.main.url(forResource: "catalogue-development", withExtension: "json") else {
                throw CatalogueError.invalid("The bundled development catalogue is missing.")
            }
            let base = try decode(Data(contentsOf: bundledURL))
            catalogue = base
            if FileManager.default.fileExists(atPath: importedURL.path) {
                let imported = try decode(Data(contentsOf: importedURL))
                catalogue = try merge(base, imported)
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func importCatalogue(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 20_000_000 else { throw CatalogueError.invalid("The catalogue must be smaller than 20 MB.") }
        let incoming = try decode(data)
        let merged = try merge(catalogue, incoming)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(merged)
        try FileManager.default.createDirectory(at: importedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: importedURL, options: [.atomic, .completeFileProtection])
        catalogue = merged
        errorMessage = nil
    }

    func brand(for product: EquipmentProduct) -> String {
        catalogue.brands.first { $0.id == product.brandID }?.name ?? "Unknown manufacturer"
    }

    func variants(for product: EquipmentProduct) -> [EquipmentVariant] { catalogue.variants.filter { $0.productID == product.id } }
    func colorways(for product: EquipmentProduct) -> [EquipmentColorway] { catalogue.colorways.filter { $0.productID == product.id } }
    func image(for product: EquipmentProduct) -> EquipmentImage? { catalogue.images.first { $0.productID == product.id } }

    private func decode(_ data: Data) throws -> EquipmentCatalogue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(EquipmentCatalogue.self, from: data)
        try validate(result)
        return result
    }

    private func merge(_ base: EquipmentCatalogue, _ other: EquipmentCatalogue) throws -> EquipmentCatalogue {
        func upsert<T: Identifiable>(_ lhs: [T], _ rhs: [T]) -> [T] where T.ID: Hashable {
            var values = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
            for value in rhs { values[value.id] = value }
            // Preserve existing catalogue order, then append new IDs in import order.
            let ids = lhs.map(\.id) + rhs.map(\.id).filter { id in !lhs.contains(where: { $0.id == id }) }
            return ids.compactMap { values[$0] }
        }
        let result = EquipmentCatalogue(schemaVersion: 1, title: "Local equipment catalogue", isDevelopmentDataset: true,
            brands: upsert(base.brands, other.brands), products: upsert(base.products, other.products),
            variants: upsert(base.variants, other.variants), colorways: upsert(base.colorways, other.colorways), images: upsert(base.images, other.images))
        try validate(result)
        return result
    }

    private func validate(_ value: EquipmentCatalogue) throws {
        func require(_ condition: Bool, _ reason: String) throws { if !condition { throw CatalogueError.invalid(reason) } }
        func valid(_ url: URL) -> Bool { url.scheme == "https" && url.host != nil }
        func unique<T: Identifiable>(_ rows: [T]) -> Bool where T.ID: Hashable { Set(rows.map(\.id)).count == rows.count }
        try require(value.schemaVersion == 1, "Unsupported catalogue schema version.")
        try require(unique(value.brands) && unique(value.products) && unique(value.variants) && unique(value.colorways) && unique(value.images), "Catalogue IDs must be unique within each collection.")
        let brands = Set(value.brands.map(\.id)), products = Set(value.products.map(\.id))
        for brand in value.brands { try require(!brand.id.isEmpty && !brand.name.isEmpty && valid(brand.website), "Every brand needs an ID, name and HTTPS website.") }
        for product in value.products {
            try require(!product.id.isEmpty && !product.modelName.isEmpty && brands.contains(product.brandID) && valid(product.sourceURL) && product.verifiedAt <= Date(), "Every product needs an existing brand, name, source and past verification date.")
        }
        for variant in value.variants { try require(!variant.id.isEmpty && products.contains(variant.productID) && valid(variant.sourceURL), "A variant references an unavailable product or source.") }
        for colorway in value.colorways { try require(!colorway.id.isEmpty && !colorway.officialName.isEmpty && products.contains(colorway.productID) && valid(colorway.sourceURL), "A colorway references an unavailable product or source.") }
        for image in value.images {
            try require(products.contains(image.productID) && valid(image.url) && valid(image.sourceURL) && !image.permission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Images need a valid product, HTTPS URLs and recorded usage permission.")
            if let colorwayID = image.colorwayID { try require(value.colorways.contains { $0.id == colorwayID && $0.productID == image.productID }, "Image colorway does not belong to its product.") }
        }
    }

    enum CatalogueError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): message } }
    }
}
