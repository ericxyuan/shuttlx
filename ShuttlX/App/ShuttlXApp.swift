import SwiftUI
import ShuttlXCore

@main struct ShuttlXApp: App {
    @State private var store = AppStore()
    @State private var navigation = AppNavigation()
    @State private var profile = ProfileStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(navigation)
                .environment(profile)
                .onOpenURL { navigation.open($0) }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(ProfileStore.self) private var profile
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardVisible = false

    var body: some View {
        ZStack {
            SectionRoot(section: .statistics) { StatisticsView() }
            SectionRoot(section: .analysis) { AnalysisView() }
            SectionRoot(section: .records) { RecordsView() }
            SectionRoot(section: .watch) { WatchControlView() }
            SectionRoot(section: .profile) { ProfileView() }
            SectionRoot(section: .settings) { SettingsView() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                ShuttlGlassNavigation(selection: Binding(get: { navigation.selection }, set: { navigation.selection = $0 }))
            }
        }
        .background(Color.shuttlBackground.ignoresSafeArea())
        .tint(.shuttlAccent)
        .preferredColorScheme(profile.appearance == "system" ? nil : (profile.appearance == "dark" ? .dark : .light))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: .shuttlIntentRoute)) { _ in navigation.consumeIntentRoute() }
        .task {
            store.startConnectivity { date in
                profile.equipment.filter {
                    $0.dateStarted <= date && ($0.dateRetired.map { date < $0 } ?? true)
                }.map(\.id)
            }
            navigation.consumeIntentRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.saveSettings(); profile.savePreferences() }
            if phase == .active { store.refresh(); navigation.consumeIntentRoute() }
        }
        .alert("ShuttlX", isPresented: Binding(get: { store.errorMessage != nil || profile.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil; profile.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil; profile.errorMessage = nil }
        } message: { Text(store.errorMessage ?? profile.errorMessage ?? "An unexpected error occurred.") }
    }
}

struct SectionRoot<Content: View>: View {
    let section: AppSection
    @ViewBuilder var content: Content
    @Environment(AppNavigation.self) private var navigation
    var body: some View {
        NavigationStack(path: Binding(get: { navigation.paths[section, default: NavigationPath()] }, set: { navigation.paths[section] = $0 })) {
            content
        }
        .opacity(navigation.selection == section ? 1 : 0)
        .allowsHitTesting(navigation.selection == section)
        .accessibilityHidden(navigation.selection != section)
        .zIndex(navigation.selection == section ? 1 : 0)
    }
}
