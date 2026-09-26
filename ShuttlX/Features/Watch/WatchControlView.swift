import SwiftUI
import ShuttlXCore

struct WatchControlView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @State private var showingScanner = false
    @State private var pairingMessage: String?
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Label(store.transfer.syncState, systemImage: store.transfer.isReachable ? "applewatch.radiowaves.left.and.right" : "applewatch")
                LabeledContent("Paired", value: store.transfer.isPaired ? "Yes" : "Not available")
                LabeledContent("Watch app", value: store.transfer.isAppInstalled ? "Installed" : "Not installed")
                if let status = store.transfer.deviceStatus {
                    LabeledContent("Device", value: status.modelName)
                    LabeledContent("watchOS", value: status.systemVersion)
                    LabeledContent("Motion", value: status.motionAvailable ? "Available" : "Unavailable")
                    LabeledContent("Tracking", value: status.trackingStatus)
                    if let battery = status.batteryLevel {
                        LabeledContent("Last reported battery", value: battery.formatted(.percent.precision(.fractionLength(0))))
                    }
                    if let rate = status.measuredSampleRateHz {
                        LabeledContent("Measured sampling", value: "\(rate.formatted(.number.precision(.fractionLength(1)))) Hz")
                    }
                    Text("Reported \(status.reportedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Open ShuttlX on your paired Watch to receive its device report.")
                        .foregroundStyle(.secondary)
                }
                Button("Refresh and retry sync", systemImage: "arrow.clockwise") { store.refresh() }
                if let error = store.transfer.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button("Scan Watch pairing QR", systemImage: "qrcode.viewfinder") { showingScanner = true }
                if let pairingMessage { Text(pairingMessage).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Connection") } footer: {
                Text("Start, pause and end sessions on your Watch. Completed sessions are saved there before background transfer to iPhone. Website pairing uses a time-limited QR code.")
            }
            Section("Watch display") {
                Picker("Preset", selection: Binding(get: { store.watchLayout.preset }, set: {
                    store.watchLayout.apply($0); store.saveWatchLayout()
                })) {
                    ForEach(WatchPreset.allCases) { Text($0.displayName).tag($0) }
                }
                metricPicker("Primary", selection: Binding(get: { store.watchLayout.primary }, set: {
                    store.watchLayout.primary = $0; store.watchLayout.preset = .custom; store.saveWatchLayout()
                }))
                metricPicker("Secondary", selection: Binding(get: { store.watchLayout.secondary }, set: {
                    store.watchLayout.secondary = $0; store.watchLayout.preset = .custom; store.saveWatchLayout()
                }))
                Picker("Third metric", selection: Binding(get: { store.watchLayout.tertiary }, set: {
                    store.watchLayout.tertiary = $0; store.watchLayout.preset = .custom; store.saveWatchLayout()
                })) {
                    Text("None").tag(Optional<WatchMetric>.none)
                    ForEach(WatchMetric.allCases) { Text($0.displayName).tag(Optional($0)) }
                }
                VStack(spacing: 12) {
                    Text("DISPLAY PREVIEW").font(.caption2).foregroundStyle(.secondary)
                    Text(store.watchLayout.primary.displayName).font(.headline)
                    Text("—").font(.largeTitle.monospacedDigit())
                    Text(store.watchLayout.secondary.displayName).font(.subheadline)
                    if let third = store.watchLayout.tertiary { Text(third.displayName).font(.caption) }
                }
                .frame(maxWidth: .infinity).padding(24)
                .background(.black, in: RoundedRectangle(cornerRadius: 32)).foregroundStyle(.white)
                Text("The preview shows layout only. Live values come from your Watch session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Watch")
        .fullScreenCover(isPresented: $showingScanner) {
            WebsitePairingScannerView(onPairingURL: { url in
                showingScanner = false
                guard let claim = Self.claimURL(from: url) else { pairingMessage = "That QR code is not a ShuttlX website pairing code."; return }
                UIApplication.shared.open(claim)
                pairingMessage = "Finish pairing in the website, then return to ShuttlX."
            }, onCancel: { showingScanner = false })
        }
        .onAppear { deliverWebsiteCredentialIfAvailable() }
        .onChange(of: navigation.routeRevision) { _, _ in deliverWebsiteCredentialIfAvailable() }
    }

    private func deliverWebsiteCredentialIfAvailable() {
        guard let url = navigation.websiteCredentialURL else { return }
        navigation.websiteCredentialURL = nil
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let baseValue = query.first(where: { $0.name == "base" })?.value,
              let baseData = Data(base64Encoded: baseValue.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - baseValue.count % 4) % 4)),
              let base = String(data: baseData, encoding: .utf8), let baseURL = URL(string: base),
              let device = query.first(where: { $0.name == "device" })?.value.flatMap(UUID.init(uuidString:)),
              let token = query.first(where: { $0.name == "token" })?.value else { pairingMessage = "The pairing response was incomplete."; return }
        store.transfer.sendWebCredential(baseURL: baseURL, deviceID: device, token: token)
        pairingMessage = "Website pairing sent to the Watch."
    }

    private static func claimURL(from qr: URL) -> URL? {
        guard let items = URLComponents(url: qr, resolvingAgainstBaseURL: false)?.queryItems,
              let encodedBase = items.first(where: { $0.name == "base" })?.value,
              let data = Data(base64Encoded: encodedBase.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - encodedBase.count % 4) % 4)),
              let baseString = String(data: data, encoding: .utf8), let base = URL(string: baseString), base.scheme == "https",
              let device = items.first(where: { $0.name == "device" })?.value,
              let nonce = items.first(where: { $0.name == "nonce" })?.value,
              let name = items.first(where: { $0.name == "name" })?.value else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("pair"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "device", value: device), URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "name", value: name)]
        return components?.url
    }

    private func metricPicker(_ title: String, selection: Binding<WatchMetric>) -> some View {
        Picker(title, selection: selection) {
            ForEach(WatchMetric.allCases) { Text($0.displayName).tag($0) }
        }
    }
}
