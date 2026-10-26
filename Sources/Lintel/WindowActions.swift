import AppKit
import ApplicationServices

@MainActor
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
        raise(window)
        // Opening an app that is already frontmost sends it a reopen event, which it answers
        // with the window of its choice: Chromium browsers come back to their main window,
        // so the tab of a sign-in popup would never reach the popup.
        guard !app.isActive else { return }
        // Chromium-based browsers accept AXFrontmost yet stay behind, and
        // NSRunningApplication.activate is slow from the background; opening the app
        // through LaunchServices, like a Dock click, always works.
        AXUIElementCreateApplication(window.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: openConfiguration) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { raiseAgain(window, attempt: 0) } }
        }
    }

    private static func raise(_ window: WindowInfo) {
        window.element.set(kAXMainAttribute, kCFBooleanTrue)
        window.element.perform(kAXRaiseAction)
    }

    /// The window the reopen event brought forward wins over the one raised before it, and
    /// the app answers in its own time: raise again until the window really has the focus.
    private static func raiseAgain(_ window: WindowInfo, attempt: Int) {
        raise(window)
        guard attempt < 3, !isFocused(window) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated { raiseAgain(window, attempt: attempt + 1) }
        }
    }

    private static func isFocused(_ window: WindowInfo) -> Bool {
        guard let focused = AXUIElementCreateApplication(window.pid).value(kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(focused, window.element)
    }

    /// Presses the window's own close button, so apps can still ask to save.
    static func close(_ window: WindowInfo) {
        guard let button = window.element.value(kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return }
        (button as! AXUIElement).perform(kAXPressAction)
    }
}
