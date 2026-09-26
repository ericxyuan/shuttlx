import SwiftUI
import ShuttlXCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ProfileStore.self) private var profile
    @State private var deletionPresented = false
    @State private var versionTaps = 0
    @State private var developerEnabled = false
    @State private var exportURL: URL?

    var body: some View {
        @Bindable var store = store
        @Bindable var profile = profile
        Form {
            Section("Player") {
                Picker("Playing hand", selection: $store.settings.playingHand) {
                    ForEach(PlayingHand.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Watch wrist", selection: $store.settings.watchWrist) {
                    ForEach(WatchWrist.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Discipline", selection: Binding(get: { profile.profile.discipline }, set: { value in
                    var next = profile.profile
                    next.discipline = value
                    do { try profile.updateProfile(next) } catch { profile.errorMessage = error.localizedDescription }
                })) {
                    ForEach(["Singles", "Doubles", "Mixed", "Multiple"], id: \.self) { Text($0).tag($0) }
                }
                if store.settings.playingHand.rawValue != store.settings.watchWrist.rawValue {
                    Label("Wear the Watch on your racket wrist to capture that arm's motion.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Tracking") {
                Picker("Sensitivity", selection: sensitivity) {
                    Text("Low").tag("low")
                    Text("Balanced").tag("balanced")
                    Text("High").tag("high")
                    Text("Custom").tag("custom")
                }
                Toggle("Auto pause", isOn: $store.settings.autoPause)
                Toggle("Shot haptics", isOn: $store.settings.hapticFeedback)
                NavigationLink("Advanced tracking") { AdvancedTrackingView() }
                NavigationLink("Player calibration") { PlayerCalibrationView() }
            }
            Section {
                Picker("Sampling request", selection: $store.settings.sampleRateHz) {
                    Text("25 Hz request").tag(25.0)
                    Text("Automatic · 50 Hz request").tag(50.0)
                    if store.settings.sampleRateHz != 25 && store.settings.sampleRateHz != 50 {
                        Text("Existing \(Int(store.settings.sampleRateHz)) Hz request").tag(store.settings.sampleRateHz)
                    }
                }
                LabeledContent("Last measured rate", value: measuredRate)
            } header: { Text("Sensors") } footer: {
                Text("Core Motion treats the interval as a request and does not enumerate supported rates. The Watch reports the delivered frequency from real timestamps. Higher rates may increase battery use.")
            }
            Section {
                LabeledContent("Minimum confidence", value: store.settings.confidenceThreshold.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $store.settings.confidenceThreshold, in: 0.5...0.99, step: 0.01)
                    .accessibilityLabel("Minimum classification confidence")
                    .accessibilityValue(store.settings.confidenceThreshold.formatted(.percent))
                Toggle("Show unknown shots", isOn: $profile.showUnknownShots)
                Toggle("Experimental classification", isOn: $store.settings.enableExperimentalClassification)
            } header: { Text("Classification") } footer: {
                Text("Events below the threshold stay Unknown. Experimental motion rules have not been validated against labelled badminton data. They do not establish rally outcomes or tactical intent.")
            }
            Section("Units") {
                Picker("Swing speed", selection: $profile.speedUnit) {
                    Text("Kilometres per hour (km/h)").tag("km/h")
                    Text("Miles per hour (mph)").tag("mph")
                }
            }
            Section {
                Picker("Keep raw sensor windows", selection: Binding(get: { store.rawRetentionDays ?? -1 }, set: { value in
                    store.rawRetentionDays = value == -1 ? nil : value
                    store.settings.retainRawSamples = value != 0
                    store.saveSettings()
                })) {
                    Text("Do not keep").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Forever").tag(-1)
                }
                Button("Export sessions and retained raw data", systemImage: "square.and.arrow.up") {
                    do { exportURL = try store.exportSessions() }
                    catch { store.errorMessage = error.localizedDescription }
                }
                if let exportURL { ShareLink("Share session JSON", item: exportURL) }
                Button("Delete all saved sessions", role: .destructive) { deletionPresented = true }
            } header: { Text("Data") } footer: {
                Text("Retention applies to raw sensor windows. Session summaries stay available. Export includes only data still retained on this iPhone; expired raw data cannot be recovered.")
            }
            Section("Appearance") {
                Picker("Appearance", selection: $profile.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            if developerEnabled {
                Section("Developer") {
                    NavigationLink("Motion replay and dataset tools") { DeveloperToolsView() }
                    Button("Hide developer tools") { developerEnabled = false; versionTaps = 0 }
                }
            }
            Section("About") {
                Button {
                    versionTaps += 1
                    if versionTaps >= 7 { developerEnabled = true }
                } label: {
                    LabeledContent("ShuttlX", value: "0.1 · Development").foregroundStyle(.primary)
                }
                Text("Wrist motion provides estimates about your swings. It does not measure shuttle speed, court placement, scores or winners.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onChange(of: store.settings) { _, _ in store.saveSettings() }
        .onChange(of: profile.speedUnit) { _, _ in profile.savePreferences() }
        .onChange(of: profile.appearance) { _, _ in profile.savePreferences() }
        .onChange(of: profile.showUnknownShots) { _, _ in profile.savePreferences() }
        .confirmationDialog("Delete all saved sessions?", isPresented: $deletionPresented, titleVisibility: .visible) {
            Button("Delete all sessions", role: .destructive) {
                do { try store.deleteAllSessions(); exportURL = nil }
                catch { store.errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes sessions and retained raw windows from this iPhone. Your profile and equipment history stay available.") }
    }

    private var measuredRate: String {
        guard let value = store.transfer.deviceStatus?.measuredSampleRateHz else { return "Not reported yet" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) Hz"
    }

    private var sensitivity: Binding<String> {
        Binding(get: {
            switch (store.settings.accelerationThreshold, store.settings.rotationThreshold) {
            case (3.2, 14): "low"
            case (2.2, 10): "balanced"
            case (1.4, 7): "high"
            default: "custom"
            }
        }, set: { value in
            switch value {
            case "low": store.settings.accelerationThreshold = 3.2; store.settings.rotationThreshold = 14
            case "balanced": store.settings.accelerationThreshold = 2.2; store.settings.rotationThreshold = 10
            case "high": store.settings.accelerationThreshold = 1.4; store.settings.rotationThreshold = 7
            default: break
            }
        })
    }
}

struct AdvancedTrackingView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                control("Acceleration threshold", value: $store.settings.accelerationThreshold, range: 0.8...8, step: 0.1, unit: "g")
                control("Rotation threshold", value: $store.settings.rotationThreshold, range: 3...35, step: 0.5, unit: "rad/s")
                control("Shot refractory period", value: $store.settings.refractoryPeriod, range: 0.3...2, step: 0.05, unit: "s")
            } header: { Text("Detection") } footer: {
                Text("Lower thresholds detect more candidates but can include ordinary arm movement. The refractory period prevents immediate duplicate events.")
            }
            Section("Capture windows") {
                control("Pre-swing", value: $store.settings.preWindow, range: 0.1...0.5, step: 0.05, unit: "s")
                control("Post-swing", value: $store.settings.postWindow, range: 0.2...0.8, step: 0.05, unit: "s")
                control("Inferred rally gap", value: $store.settings.rallyGap, range: 2...20, step: 0.5, unit: "s")
            }
            Section { Text("Changes apply on the Watch at the next session. Rally grouping uses gaps between your detected strokes, not both players' shots.").font(.caption).foregroundStyle(.secondary) }
            Section {
                Button("Restore balanced detection") {
                    let defaults = TrackingSettings()
                    store.settings.accelerationThreshold = defaults.accelerationThreshold
                    store.settings.rotationThreshold = defaults.rotationThreshold
                    store.settings.refractoryPeriod = defaults.refractoryPeriod
                    store.settings.preWindow = defaults.preWindow
                    store.settings.postWindow = defaults.postWindow
                    store.settings.rallyGap = defaults.rallyGap
                }
            }
        }
        .navigationTitle("Advanced tracking")
        .onChange(of: store.settings) { _, _ in store.saveSettings() }
    }

    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: "\(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))) \(unit)")
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
                .accessibilityValue("\(value.wrappedValue.formatted()) \(unit)")
        }.padding(.vertical, 4)
    }
}

struct PlayerCalibrationView: View {
    @Environment(AppStore.self) private var store
    @State private var radius: Double?
    @State private var direction = 0
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        Form {
            Section {
                Text("Experimental calibration parameters").font(.headline)
                Text("ShuttlX does not yet provide validated player calibration. These optional parameters are for comparing recorded motion with external measurements. A saved parameter is not evidence of calibrated accuracy.")
            }
            Section {
                TextField("Measured effective lever arm (metres)", value: $radius, format: .number)
                    .keyboardType(.decimalPad)
                Text("Accepted range: 0.05–1.20 m. Leave empty to keep estimated swing speed unavailable. The estimate uses angular velocity × effective radius; wrist rotation alone cannot determine racket or shuttle speed.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Speed estimate") }
            Section {
                Picker("Labelled forehand rotation direction", selection: $direction) {
                    Text("Not mapped").tag(0)
                    Text("Positive Watch z-axis").tag(1)
                    Text("Negative Watch z-axis").tag(-1)
                }
                Text("Set this only after inspecting a labelled recording from the actual wearing wrist and orientation. Hand inference remains experimental.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Wrist mapping") }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("Save experimental parameters") {
                    guard radius.map({ $0.isFinite && (0.05...1.2).contains($0) }) ?? true else {
                        error = "Enter an effective radius between 0.05 and 1.20 m, or leave it empty."; return
                    }
                    store.settings.calibratedLeverArmMeters = radius
                    store.settings.handCalibrationSign = direction == 0 ? nil : Double(direction)
                    store.saveSettings()
                    error = nil
                }
                Button("Reset calibration", role: .destructive) {
                    radius = nil; direction = 0
                    store.settings.calibratedLeverArmMeters = nil
                    store.settings.handCalibrationSign = nil
                    store.saveSettings()
                }
            }
        }
        .navigationTitle("Player calibration")
        .task {
            guard !loaded else { return }
            loaded = true
            radius = store.settings.calibratedLeverArmMeters
            direction = Int(store.settings.handCalibrationSign ?? 0)
        }
    }
}
