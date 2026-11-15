import SwiftUI
import AppKit

/// Entry point: command-line test tools, otherwise the normal app.
@main
enum EntryPoint {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            SelfTest.run(Array(args[(i + 1)...]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--benchmark") {
            SelfTest.benchmark(Array(args[(i + 1)...]))
            exit(0)
        }
        DupeSweepApp.main()
    }
}

struct DupeSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("DupeSweep") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 680)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed so the app gets a Dock icon and focus when launched from Terminal.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
