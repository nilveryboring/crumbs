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
                .frame(width: 520, height: 360)
        }
    }
}
