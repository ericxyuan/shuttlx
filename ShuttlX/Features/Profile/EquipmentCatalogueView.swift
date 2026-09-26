import SwiftUI
import UniformTypeIdentifiers

struct EquipmentCatalogueView: View {
    let category: EquipmentCategory
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var brand = ""
    @State private var generation = ""
    @State private var colorway = ""
    @State private var weight = ""
    @State private var grip = ""
    @State private var year = ""
    @State private var importing = false
    @State private var error: String?

    private var catalogue: CatalogService { profile.catalogue }
    private var categoryProducts: [EquipmentProduct] { catalogue.catalogue.products.filter { $0.category == category } }
    private var results: [EquipmentProduct] {
        categoryProducts.filter { product in
            let variants = catalogue.variants(for: product)
            let colors = catalogue.colorways(for: product)
            let searchable = ([product.modelName, catalogue.brand(for: product), product.generation ?? ""] + variants.map(\.label) + colors.map(\.officialName)).joined(separator: " ")
            return (query.isEmpty || searchable.localizedCaseInsensitiveContains(query))
                && (brand.isEmpty || product.brandID == brand)
                && (generation.isEmpty || product.generation == generation)
                && (colorway.isEmpty || colors.contains { $0.officialName == colorway })
                && (weight.isEmpty || variants.contains { $0.weightClass == weight })
                && (grip.isEmpty || variants.contains { $0.gripSize == grip })
                && (year.isEmpty || product.releaseYear.map(String.init) == year)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("A small development catalogue, sourced from manufacturer pages. It is not a complete global catalogue.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    DisclosureGroup("Filters") { filterControls }
                }
                if let error = error ?? catalogue.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                if catalogue.isLoading {
                    ProgressView("Loading equipment catalogue…")
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                    Text("Try clearing filters, or import additional manufacturer-sourced products.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Section("\(results.count) products") {
                        ForEach(results) { product in
                            NavigationLink {
                                EquipmentSelectionView(product: product) { dismiss() }
                            } label: {
                                HStack(spacing: 16) {
                                    EquipmentArtwork(category: category, image: catalogue.image(for: product))
                                        .frame(width: 78, height: 88)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(catalogue.brand(for: product)).font(.caption).foregroundStyle(.secondary)
                                        Text(product.modelName).font(.headline)
                                        if let generation = product.generation { Text(generation).font(.caption).foregroundStyle(.secondary) }
                                        Text("\(catalogue.variants(for: product).count) specifications · \(catalogue.colorways(for: product).count) colors")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .navigationTitle(category.title)
            .searchable(text: $query, prompt: "Brand, model, specification or color")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Import", systemImage: "square.and.arrow.down") { importing = true } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do { try catalogue.importCatalogue(from: result.get()); error = nil }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private var filterControls: some View {
        Picker("Brand", selection: $brand) {
            Text("All brands").tag("")
            ForEach(catalogue.catalogue.brands.filter { value in categoryProducts.contains { $0.brandID == value.id } }) { Text($0.name).tag($0.id) }
        }
        facet("Generation", values: categoryProducts.compactMap(\.generation), selection: $generation)
        facet("Color", values: categoryProducts.flatMap { catalogue.colorways(for: $0).map(\.officialName) }, selection: $colorway)
        if category == .racket {
            facet("Weight", values: categoryProducts.flatMap { catalogue.variants(for: $0).compactMap(\.weightClass) }, selection: $weight)
            facet("Grip size", values: categoryProducts.flatMap { catalogue.variants(for: $0).compactMap(\.gripSize) }, selection: $grip)
        }
        facet("Release year", values: categoryProducts.compactMap { $0.releaseYear.map(String.init) }, selection: $year)
        Button("Clear filters") { brand = ""; generation = ""; colorway = ""; weight = ""; grip = ""; year = "" }
    }

    private func facet(_ title: String, values: [String], selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("All").tag("")
            ForEach(Array(Set(values)).sorted(), id: \.self) { Text($0).tag($0) }
        }.disabled(values.isEmpty)
    }
}

struct EquipmentArtwork: View {
    let category: EquipmentCategory
    let image: EquipmentImage?
    var body: some View {
        Group {
            if let image {
                AsyncImage(url: image.url) { phase in
                    switch phase {
                    case .success(let loaded): loaded.resizable().scaledToFit().accessibilityLabel(image.altText)
                    case .failure: placeholder
                    case .empty: ProgressView().accessibilityLabel("Loading product image")
                    @unknown default: placeholder
                    }
                }
            } else { placeholder }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.shuttlAccent.opacity(0.06), in: .rect(cornerRadius: 16))
    }
    private var placeholder: some View {
        VStack(spacing: 5) {
            Image(systemName: category.symbol).font(.title2).foregroundStyle(Color.shuttlAccent)
            Text("No image").font(.caption2).foregroundStyle(.secondary)
        }.accessibilityLabel("Product image unavailable")
    }
}

struct EquipmentSelectionView: View {
    let product: EquipmentProduct
    let onAdded: () -> Void
    @Environment(ProfileStore.self) private var profile
    @State private var variantID: String?
    @State private var colorwayID: String?
    @State private var started = Date()
    @State private var shoeSize = ""
    @State private var mainTension: Double?
    @State private var crossTension: Double?
    @State private var notes = ""
    @State private var error: String?
    private var catalogue: CatalogService { profile.catalogue }
    private var variants: [EquipmentVariant] { catalogue.variants(for: product) }
    private var colorways: [EquipmentColorway] { catalogue.colorways(for: product) }
    private var canAdd: Bool { (variants.isEmpty || variantID != nil) && (colorways.isEmpty || colorwayID != nil) }

    var body: some View {
        Form {
            Section {
                EquipmentArtwork(category: product.category, image: catalogue.image(for: product)).frame(height: 150)
                Text(catalogue.brand(for: product)).font(.subheadline).foregroundStyle(.secondary)
                Text(product.modelName).font(.title2.bold())
                if !product.description.isEmpty { Text(product.description).font(.subheadline) }
                Link("Manufacturer source", destination: product.sourceURL)
                Text("Source checked \(product.verifiedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("1 · Choose specification") {
                if variants.isEmpty { Text("No verified specifications in this catalogue.").foregroundStyle(.secondary) }
                ForEach(variants) { variant in
                    Button { variantID = variant.id } label: {
                        choiceRow(variant.label, selected: variantID == variant.id)
                    }.buttonStyle(.plain)
                }
            }
            Section("2 · Choose colorway") {
                if colorways.isEmpty { Text("No verified colorways in this catalogue.").foregroundStyle(.secondary) }
                ForEach(colorways) { color in
                    Button { colorwayID = color.id } label: {
                        choiceRow(color.officialName, selected: colorwayID == color.id)
                    }.buttonStyle(.plain)
                }
            }
            Section("3 · Your setup") {
                DatePicker("Date started", selection: $started, in: ...Date(), displayedComponents: .date)
                if product.category == .shoes { TextField("Your shoe size and system (e.g. 24.5 cm)", text: $shoeSize) }
                if product.category == .strings {
                    TextField("Main tension (lb, optional)", value: $mainTension, format: .number).keyboardType(.decimalPad)
                    TextField("Cross tension (lb, optional)", value: $crossTension, format: .number).keyboardType(.decimalPad)
                }
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                if profile.currentEquipment(product.category) != nil {
                    Text("Adding this setup retires your current \(product.category.title.lowercased()) on the selected start date.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section { Button("Add to profile") { add() }.disabled(!canAdd) }
        }
        .navigationTitle("Equipment details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choiceRow(_ label: String, selected: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.shuttlAccent : Color.secondary)
        }.accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func add() {
        guard canAdd else { return }
        guard [mainTension, crossTension].compactMap({ $0 }).allSatisfy({ $0.isFinite && (1...50).contains($0) }) else {
            error = "Enter tension between 1 and 50 lb, or leave the field empty."; return
        }
        let variant = variants.first { $0.id == variantID }
        let color = colorways.first { $0.id == colorwayID }
        let item = UserEquipment(productID: product.id, variantID: variantID, colorwayID: colorwayID,
                                 category: product.category, manufacturer: catalogue.brand(for: product), modelName: product.modelName,
                                 variantLabel: variant?.label, colorwayName: color?.officialName,
                                 shoeSize: shoeSize.isEmpty ? nil : shoeSize, mainTensionLB: mainTension, crossTensionLB: crossTension,
                                 notes: notes, dateStarted: started)
        do { try profile.addEquipment(item); onAdded() }
        catch { self.error = error.localizedDescription }
    }
}
