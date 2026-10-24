import AppKit
import ApplicationServices

/// Dock badges, read through Accessibility. The Dock posts nothing when a badge changes,
/// so badges are re-read every 2 s and on app switches; the full Dock scan is rarer.
@MainActor
final class BadgeMonitor {
    private(set) var badges: [pid_t: String] = [:]
    var onChange: (() -> Void)?

    private var apps: () -> [pid_t: NSRunningApplication] = { [:] }
    private var dockItems: [String: AXUIElement] = [:]
    /// The Dock the items were read from: a restarted Dock invalidates all of them.
    private var dock: NSRunningApplication?
    private var timer: Timer?
    private var lastScan = Date.distantPast

    /// Stops the 2 s polling, e.g. while the screens sleep.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            timer?.invalidate()
            timer = nil
            guard !isPaused else { return }
            startTimer()
            refresh()
        }
    }

    func start(apps: @escaping () -> [pid_t: NSRunningApplication]) {
        self.apps = apps
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The Dock adds or removes the icon shortly after.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        self?.scanDock()
                        self?.refresh()
                    }
                }
            }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if !isPaused { startTimer() }
        scanDock()
        refresh()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
    }

    private func refresh() {
        var found: [pid_t: String] = [:]
        var missing = false
        for (pid, app) in apps() {
            guard let path = app.bundleURL.map(Self.key) else { continue }
            guard let item = dockItems[path] else {
                missing = true
                continue
            }
            var value: CFTypeRef?
            // A restarted Dock has new elements: rescan, and keep the badges until the next read.
            if dock?.isTerminated == true
                || AXUIElementCopyAttributeValue(item, "AXStatusLabel" as CFString, &value) == .invalidUIElement {
                scanDock()
                return
            }
            if let label = value as? String, !label.isEmpty {
                found[pid] = label
            }
        }
        // Unknown to the last scan: rescan, at most every 10 s.
        if missing, Date().timeIntervalSince(lastScan) > 10 {
            scanDock()
        }
        guard found != badges else { return }
        badges = found
        onChange?()
    }

    private func scanDock() {
        lastScan = Date()
        dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        guard let dock else {
            dockItems = [:]
            return
        }
        var items: [String: AXUIElement] = [:]
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        for list in root.value(kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            for item in list.value(kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard item.value(kAXSubroleAttribute) as? String == "AXApplicationDockItem",
                      let url = item.value(kAXURLAttribute) as? URL
                else { continue }
                items[Self.key(url)] = item
            }
        }
        dockItems = items
    }

    /// The Dock and NSRunningApplication may spell a path differently (/tmp vs /private/tmp).
    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
