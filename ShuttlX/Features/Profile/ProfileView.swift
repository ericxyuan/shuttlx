import SwiftUI
import ShuttlXCore

struct ProfileView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var category: EquipmentCategory?
    @State private var exportURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ShuttlCard(title: profile.profile.name.isEmpty ? "Your player profile" : profile.profile.name,
                           subtitle: profile.profile.country.isEmpty ? nil : profile.profile.country) {
                    HStack(alignment: .center, spacing: 20) {
                        PlayerAvatar(data: profile.profile.photoData, size: 88)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(store.settings.playingHand.displayName) handed").font(.headline)
                            Text(profile.profile.discipline).foregroundStyle(.secondary)
                            if !profile.profile.style.isEmpty { Text(profile.profile.style).font(.subheadline) }
                        }
                    }
                    if let height = profile.profile.heightCM { ShuttlStatRow(label: "Height", value: height.formatted(), unit: "cm") }
                    if let weight = profile.profile.weightKG { ShuttlStatRow(label: "Weight", value: weight.formatted(), unit: "kg") }
                    if let strings = profile.currentEquipment(.strings), let main = strings.mainTensionLB, let cross = strings.crossTensionLB {
                        ShuttlStatRow(label: "String tension", value: "\(main.formatted()) × \(cross.formatted())", unit: "lb")
                    }
                    Button("Edit profile", systemImage: "pencil") { editing = true }.buttonStyle(.bordered)
                }
                ShuttlSectionHeader(title: "My equipment", subtitle: "Your current setup, with its history preserved")
                ForEach(EquipmentCategory.allCases) { item in equipmentCard(item) }
                NavigationLink { EquipmentHistoryView() } label: {
                    Label("Equipment history", systemImage: "clock.arrow.circlepath")
                }.buttonStyle(.bordered)
                Button("Prepare profile export", systemImage: "square.and.arrow.up") {
                    do { exportURL = try profile.exportProfile() }
                    catch { profile.errorMessage = error.localizedDescription }
                }
                if let exportURL { ShareLink("Share profile JSON", item: exportURL) }
            }
            .padding(20)
        }
        .navigationTitle("Profile")
        .sheet(isPresented: $editing) { ProfileEditor(initial: profile.profile) }
        .sheet(item: $category) { EquipmentCatalogueView(category: $0) }
    }

    private func equipmentCard(_ category: EquipmentCategory) -> some View {
        let item = profile.currentEquipment(category)
        return ShuttlCard(title: category.title) {
            HStack(spacing: 16) {
                EquipmentArtwork(category: category, image: nil)
                    .frame(width: 76, height: 82)
                VStack(alignment: .leading, spacing: 5) {
                    if let item {
                        Text(item.manufacturer).font(.caption).foregroundStyle(.secondary)
                        Text(item.modelName).font(.headline)
                        if let variant = item.variantLabel { Text(variant).font(.subheadline).foregroundStyle(.secondary) }
                        if let color = item.colorwayName { Text(color).font(.subheadline).foregroundStyle(.secondary) }
                        Text("Since \(item.dateStarted.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Add your \(category.title.lowercased())").font(.headline)
                        Text("Choose a model and the specification you use.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(item == nil ? "Choose equipment" : "Replace equipment") { self.category = category }
                    .buttonStyle(.bordered)
                if let item {
                    NavigationLink("Details") { EquipmentHistoryEditor(initial: item) }
                }
            }
        }
    }
}

struct PlayerAvatar: View {
    let data: Data?
    var size: CGFloat = 80
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.shuttlAccent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityLabel(data == nil ? "Default player avatar" : "Player photo")
    }
}
