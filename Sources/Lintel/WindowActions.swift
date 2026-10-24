import AppKit
import ApplicationServices

enum WindowActions {
    private static let openConfiguration: NSWorkspace.OpenConfiguration = {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        return configuration
    }()

    /// Raises the window before activating its app, so it is the one that lands on top.
    static func activate(_ window: WindowInfo, app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        if window.isMinimized { window.element.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        window.element.set(kAXMainAttribute, kCFBooleanTrue)
        window.element.perform(kAXRaiseAction)
        // Chromium-based browsers accept AXFrontmost yet stay behind, and
        // NSRunningApplication.activate is slow from the background; opening the app
        // through LaunchServices, like a Dock click, always works.
        AXUIElementCreateApplication(window.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
        if let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: openConfiguration)
        }
    }

    /// Presses the window's own close button, so apps can still ask to save.
    static func close(_ window: WindowInfo) {
        guard let button = window.element.value(kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return }
        (button as! AXUIElement).perform(kAXPressAction)
    }
}
