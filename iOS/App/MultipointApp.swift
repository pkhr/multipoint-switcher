import AppIntents
import SwiftUI

@main
struct MultipointApp: App {
    init() {
        // Controls and shortcuts launch the app in the background, with no window; be ready for them here.
        HeadphoneCommands.handler = HeadphoneStore.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(HeadphoneStore.shared)
        }
    }
}

struct MultipointShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SwitchSourceIntent(),
                    phrases: ["Switch headphones with \(.applicationName)", "Switch \(.applicationName) source"],
                    shortTitle: "Switch Source", systemImageName: "arrow.left.arrow.right")
        AppShortcut(intent: CycleNoiseModeIntent(),
                    phrases: ["Change noise control with \(.applicationName)"],
                    shortTitle: "Change Noise Control", systemImageName: "person.wave.2.fill")
        AppShortcut(intent: SetNoiseModeIntent(),
                    phrases: ["Set \(.applicationName) noise control", "Set \(.applicationName) to \(\.$mode)"],
                    shortTitle: "Set Noise Control", systemImageName: "person.fill")
    }
}
