import CrumbsCore
import SwiftUI

@main
struct CrumbsApp: App {
    @State private var store = CrumbStore()

    init() {
        #if DEBUG
        DebugSnapshot.startIfRequested()
        #endif
    }

    var body: some Scene {
        Window("Crumbs", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1240, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Now") { store.scan() }
                    .keyboardShortcut("r")
                    .disabled(store.isScanning)
            }
            CommandGroup(replacing: .help) {
                Link("Send Feedback…", destination: Links.feedback)
                Link("Crumbs Website", destination: Links.website)
                Link("Source on GitHub", destination: Links.github)
                Link("Privacy Policy", destination: Links.privacy)
            }
        }

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            Image(nsImage: CookieArt.menuBarImage())
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .frame(width: 600, height: 560)
        }
    }
}

enum Links {
    static let website = URL(string: "https://www.nilni.com/crumbs")!
    static let privacy = URL(string: "https://www.nilni.com/crumbs/privacy")!
    static let github = URL(string: "https://github.com/nilveryboring/crumbs")!
    /// Lands on nilni.com, which forwards to the current feedback form, so the
    /// form can change without shipping a new app.
    static var feedback: URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return URL(string: "https://www.nilni.com/crumbs/feedback?from=app&v=\(version)")!
    }
}
