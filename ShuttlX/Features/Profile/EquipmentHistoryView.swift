import SwiftUI

struct EquipmentHistoryView: View {
    @Environment(ProfileStore.self) private var profile
    var body: some View {
        List {
            if profile.equipment.isEmpty {
                ContentUnavailableView("Add your equipment", systemImage: "clock.arrow.circlepath",
                                       description: Text("Current and previous setups appear here after you add them to your profile."))
            }
            ForEach(EquipmentCategory.allCases) { category in
                let items = profile.equipment.filter { $0.category == category }.sorted { $0.dateStarted > $1.dateStarted }
                if !items.isEmpty {
                    Section(category.title) {
                        ForEach(items) { item in
                            NavigationLink { EquipmentHistoryEditor(initial: item) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(item.manufacturer) \(item.modelName)").font(.headline)
                                    Text(item.variantLabel ?? "Specification not recorded").font(.subheadline).foregroundStyle(.secondary)
                                    Text("\(item.dateStarted.formatted(date: .abbreviated, time: .omitted)) – \(item.dateRetired?.formatted(date: .abbreviated, time: .omitted) ?? "Current")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Equipment history")
    }
}

struct EquipmentHistoryEditor: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var draft: UserEquipment
    @State private var error: String?
    init(initial: UserEquipment) { _draft = State(initialValue: initial) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Manufacturer", value: draft.manufacturer)
                LabeledContent("Model", value: draft.modelName)
                if let value = draft.variantLabel { LabeledContent("Specification", value: value) }
                if let value = draft.colorwayName { LabeledContent("Colorway", value: value) }
                if let value = draft.shoeSize { LabeledContent("Shoe size", value: value) }
                if let value = draft.mainTensionLB { LabeledContent("Main tension", value: "\(value.formatted()) lb") }
                if let value = draft.crossTensionLB { LabeledContent("Cross tension", value: "\(value.formatted()) lb") }
            }
            Section("Dates") {
                DatePicker("Date started", selection: $draft.dateStarted, in: ...Date(), displayedComponents: .date)
                Toggle("Retired", isOn: Binding(get: { draft.dateRetired != nil }, set: { draft.dateRetired = $0 ? max(draft.dateStarted, .now) : nil }))
                if draft.dateRetired != nil {
                    DatePicker("Date retired", selection: Binding(get: { draft.dateRetired ?? .now }, set: { draft.dateRetired = $0 }),
                               in: draft.dateStarted...max(draft.dateStarted, .now), displayedComponents: .date)
                }
            }
            Section("Notes") { TextField("Notes", text: $draft.notes, axis: .vertical) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("Save changes") {
                    do { try profile.updateEquipment(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.navigationTitle("Equipment history").navigationBarTitleDisplayMode(.inline)
    }
}
