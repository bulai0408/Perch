import SwiftUI

/// The app: owns the stores and hands them to every screen through the environment.
@main
struct PerchApp: App {
    @State private var connection: ConnectionStore
    @State private var quotas = QuotasStore()
    @State private var routing = RoutingStore()
    @State private var usage = UsageStore()
    @State private var versions = VersionStore()

    /// Applies the `-perch-reset` / `PERCH_RESET=1` test hook (and, in DEBUG,
    /// the demo seed) before the connection store reads what is saved.
    init() {
        // UI tests start from nothing saved.
        if ProcessInfo.processInfo.arguments.contains("-perch-reset") || ProcessInfo.processInfo.environment["PERCH_RESET"] == "1" {
            ConnectionStore().removeAll()
            for key in [VersionStore.dismissedKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
        #if DEBUG
        if DemoData.isOn {
            ConnectionStore().seedDemo(DemoData.computers())
        }
        #endif
        _connection = State(initialValue: ConnectionStore())
        PerchType.installNavigationTitles()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .environment(quotas)
                .environment(routing)
                .environment(usage)
                .environment(versions)
        }
    }
}
