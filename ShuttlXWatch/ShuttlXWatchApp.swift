import SwiftUI

@main struct ShuttlXWatchApp: App {
    @State private var controller = WatchSessionController()
    var body: some Scene { WindowGroup { WatchRootView().environment(controller) } }
}
