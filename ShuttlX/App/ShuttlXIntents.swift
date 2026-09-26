import AppIntents
import Foundation

extension Notification.Name {
    static let shuttlIntentRoute = Notification.Name("ShuttlX.intentRoute")
}

struct OpenAnalysisIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Analysis"
    static var description = IntentDescription("Open ShuttlX on the Analysis section.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("analysis", forKey: "intentDestination")
        NotificationCenter.default.post(name: .shuttlIntentRoute, object: nil)
        return .result()
    }
}

struct OpenRecordsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Records"
    static var description = IntentDescription("Open ShuttlX on the Records section.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("records", forKey: "intentDestination")
        NotificationCenter.default.post(name: .shuttlIntentRoute, object: nil)
        return .result()
    }
}

struct ShuttlXShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenAnalysisIntent(), phrases: ["Open my \(.applicationName) analysis"], shortTitle: "Open Analysis", systemImageName: "chart.xyaxis.line")
        AppShortcut(intent: OpenRecordsIntent(), phrases: ["Show my \(.applicationName) personal bests"], shortTitle: "Open Records", systemImageName: "trophy")
    }
}
