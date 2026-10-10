//
//  AppDelegate.swift
//  Hoot
//
//  Hoot's app exists only so Safari can find the extension inside it. It has no window and no Dock
//  icon (LSUIElement): opening it takes you straight to Hoot in Safari's Extensions settings, then
//  it quits. If Safari can't show Hoot yet (e.g. right after installing, before Safari has noticed
//  the extension), it retries briefly and then explains what to do instead of quitting silently.
//

import Cocoa
import SafariServices

@main
enum HootApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate() // NSApplication holds its delegate weakly; this stays alive in run()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The extension is always the app's bundle ID + ".Extension" (see BUNDLE_ID_PREFIX in the project).
    private let extensionIdentifier = (Bundle.main.bundleIdentifier ?? "net.bedar.Hoot") + ".Extension"
    private let attempts = 4
    private let retryDelay: TimeInterval = 1.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        openExtensionSettings(attempt: 1)
    }

    private func openExtensionSettings(attempt: Int) {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionIdentifier) { error in
            DispatchQueue.main.async {
                guard let error else { return NSApp.terminate(nil) }
                if attempt < self.attempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay) {
                        self.openExtensionSettings(attempt: attempt + 1)
                    }
                } else {
                    NSLog("Hoot: couldn't open Safari's Extensions settings: \(error)")
                    self.explainManualSetup()
                }
            }
        }
    }

    private func explainManualSetup() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Turn on Hoot in Safari"
        alert.informativeText = "Open Safari, choose Safari → Settings → Extensions, tick Hoot, and allow it on youtube.com."
        alert.addButton(withTitle: "Open Safari")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn,
           let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.openApplication(at: safari, configuration: .init())
        }
        NSApp.terminate(nil)
    }
}
