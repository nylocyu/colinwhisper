import AppKit
import Sparkle
import SwiftUI

@main
struct ColinWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller, updater: appDelegate.updater.updater)
        } label: {
            Image(systemName: appDelegate.controller.menuIcon)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    /// Checks the GitHub appcast daily (SUEnableAutomaticChecks) and on demand from the menu.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launch()
    }
}

private struct MenuContent: View {
    let controller: DictationController
    let updater: SPUUpdater
    @AppStorage(DefaultsKey.triggerKey) private var trigger = TriggerKey.rightCommand

    var body: some View {
        Text(controller.statusText(trigger: trigger))
        if let reason = controller.formatterUnavailableReason {
            Text("Nur unformatiert: \(reason)")
        }
        ForEach(controller.permissions.missing) { permission in
            Button("\(permission.name) erlauben…") { NSWorkspace.shared.open(permission.settingsURL) }
        }

        Divider()
        Button("Letztes Ergebnis erneut einfügen", action: controller.pasteLast)
            .disabled(controller.lastResult == nil)
        Button("Letztes Ergebnis kopieren", action: controller.copyLast)
            .disabled(controller.lastResult == nil)

        Divider()
        Button("Korrekturfenster öffnen", action: controller.showCorrection)
        Button("Glossar verwalten…", action: controller.showGlossary)
        Button("Einstellungen…", action: controller.showSettings)
            .keyboardShortcut(",")
        Button("Nach Updates suchen…", action: updater.checkForUpdates)

        Divider()
        Button("Beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
