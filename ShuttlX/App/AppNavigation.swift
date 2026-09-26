import SwiftUI
import Observation

enum AppSection: String, CaseIterable, Identifiable, Codable {
    case statistics, analysis, records, watch, profile, settings
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .statistics: "chart.bar.xaxis"
        case .analysis: "chart.xyaxis.line"
        case .records: "trophy"
        case .watch: "applewatch"
        case .profile: "person.crop.circle"
        case .settings: "gearshape"
        }
    }
}

@Observable @MainActor final class AppNavigation {
    var selection: AppSection = .analysis
    var paths: [AppSection: NavigationPath] = Dictionary(uniqueKeysWithValues: AppSection.allCases.map { ($0, NavigationPath()) })
    var requestedSessionID: UUID?
    var scannedWebsitePairingURL: URL?
    var websiteCredentialURL: URL?
    var routeRevision = 0

    func consumeIntentRoute() {
        guard let value = UserDefaults.standard.string(forKey: "intentDestination"),
              let section = AppSection(rawValue: value) else { return }
        UserDefaults.standard.removeObject(forKey: "intentDestination")
        selection = section
        paths[section] = NavigationPath()
        requestedSessionID = nil
        routeRevision += 1
    }

    func open(_ url: URL) {
        guard url.scheme == "shuttlx" else { return }
        if url.host == "website-pair" {
            scannedWebsitePairingURL = url
            selection = .watch
            paths[.watch] = NavigationPath()
            routeRevision += 1
            return
        }
        if url.host == "website-paired" {
            websiteCredentialURL = url
            selection = .watch
            paths[.watch] = NavigationPath()
            routeRevision += 1
            return
        }
        guard let section = AppSection(rawValue: url.host ?? "") else { return }
        selection = section
        paths[section] = NavigationPath()
        requestedSessionID = nil
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { $0.name == "session" })?.value {
            requestedSessionID = UUID(uuidString: value)
        }
        routeRevision += 1
    }
}

struct ShuttlGlassNavigation: View {
    @Binding var selection: AppSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var namespace

    var body: some View {
        Group {
            if #available(iOS 26.0, *), !reduceTransparency {
                GlassEffectContainer(spacing: 4) { destinations }
                    .padding(6)
                    .glassEffect(.regular, in: .rect(cornerRadius: typeSize.isAccessibilitySize ? 28 : 36))
            } else {
                destinations.padding(6)
                    .background(reduceTransparency ? AnyShapeStyle(Color.shuttlSurface) : AnyShapeStyle(.regularMaterial),
                                in: RoundedRectangle(cornerRadius: typeSize.isAccessibilitySize ? 28 : 36))
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
    }

    @ViewBuilder private var destinations: some View {
        if typeSize.isAccessibilitySize {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 4) {
                ForEach(AppSection.allCases) { section in destination(section, showLabel: true) }
            }
        } else {
            HStack(spacing: 2) {
                ForEach(AppSection.allCases) { section in destination(section, showLabel: section == selection) }
            }
        }
    }

    private func destination(_ section: AppSection, showLabel: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) { selection = section }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: section.symbol).font(.system(size: 20, weight: section == selection ? .semibold : .regular))
                if showLabel { Text(section.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8) }
            }
            .foregroundStyle(section == selection ? Color.shuttlAccent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 2)
            .contentShape(Capsule())
            .background { if section == selection { selectionSurface } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(section == selection ? [.isSelected] : [])
        .accessibilityIdentifier("tab.\(section.rawValue)")
    }

    @ViewBuilder private var selectionSurface: some View {
        if #available(iOS 26, *), !reduceTransparency {
            Capsule().fill(.clear)
                .glassEffect(.regular.tint(.shuttlAccent.opacity(0.14)).interactive(), in: .capsule)
                .glassEffectID("selection", in: namespace)
        } else {
            Capsule().fill(Color.shuttlAccent.opacity(0.12))
                .matchedGeometryEffect(id: "selection", in: namespace)
        }
    }
}
