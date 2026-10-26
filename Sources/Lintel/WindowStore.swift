import AppKit
import ApplicationServices
import OSLog
import LintelCore

private let log = Logger(subsystem: "io.github.gaetandrn.lintel", category: "store")

struct WindowInfo {
    let key: ElementKey
    let pid: pid_t
    var title: String
    /// Accessibility coordinates (top-left origin).
    var frame: CGRect
    var isMinimized: Bool
    /// Tab position: first-seen order, changed only by dragging tabs.
    var order: Int

    var element: AXUIElement { key.element }
}

/// Standard windows of regular apps on the current Space, from Accessibility notifications.
@MainActor
final class WindowStore {
    private(set) var windows: [ElementKey: WindowInfo] = [:]
    private(set) var apps: [pid_t: NSRunningApplication] = [:]
    /// Cached: NSRunningApplication's localizedName and isHidden query the system on every read.
    private(set) var appNames: [pid_t: String] = [:]
    private(set) var hiddenApps: Set<pid_t> = []
    private(set) var focused: ElementKey?

    /// Called once per run loop turn after any change.
    var onChange: (() -> Void)?
    var onGeometry: ((WindowInfo) -> Void)?
    /// Starting rank of a newly seen window; defaults to last.
    var initialRank: ((pid_t, Int) -> Int)?

    private let hub = AXObserverHub()
    private var order: [ElementKey: Int] = [:]
    /// When each window was first seen: CallMonitor tells the call window by the one the
    /// app opened as the microphone started.
    private var firstSeen: [ElementKey: Date] = [:]
    private var nextOrder = 0
    private var changeScheduled = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        // AX calls run on the main thread: a hung app must not freeze the bar for 6 s (the default).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.15)
        hub.handler = { [unowned self] name, element in handle(name, element) }

        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping (NSRunningApplication?) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { body(app) }
            }
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [unowned self] in $0.map { track($0) } }
        on(NSWorkspace.didTerminateApplicationNotification) { [unowned self] in $0.map { untrack($0) } }
        on(NSWorkspace.didActivateApplicationNotification) { [unowned self] app in
            guard let pid = app?.processIdentifier else { return }
            // Also resyncs the app's windows, in case a notification was missed. An app that
            // answered Accessibility only after its launch retries ran out gets observed here.
            if apps[pid] != nil {
                hub.observe(pid: pid)
                reload(pid)
            }
            readFocus(of: pid)
        }
        on(NSWorkspace.didHideApplicationNotification) { [unowned self] app in
            if let pid = app?.processIdentifier { hiddenApps.insert(pid) }
            scheduleChange()
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [unowned self] app in
            if let pid = app?.processIdentifier { hiddenApps.remove(pid) }
            scheduleChange()
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [unowned self] _ in
            apps.keys.forEach { reload($0) }
            // Windows mid-transition read as non-standard: read again once it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                apps.keys.forEach { self.reload($0) }
            }
        }

        NSWorkspace.shared.runningApplications.forEach { track($0) }
        if let front = NSWorkspace.shared.frontmostApplication { readFocus(of: front.processIdentifier) }
    }

    func firstSeen(of element: AXUIElement) -> Date? { firstSeen[ElementKey(element: element)] }

    func windowCount(pid: pid_t) -> Int {
        windows.values.reduce(0) { $0 + ($1.pid == pid ? 1 : 0) }
    }

    func markFocused(_ key: ElementKey) {
        focused = key
        scheduleChange()
    }

    func reorder(_ keys: [ElementKey]) {
        guard let ranks = reassignedRanks(newOrder: keys, ranks: order) else { return }
        for (key, rank) in ranks {
            order[key] = rank
            windows[key]?.order = rank
        }
        scheduleChange()
    }

    // MARK: - Apps

    private func track(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ownPID, !app.isTerminated else { return }
        apps[pid] = app
        appNames[pid] = app.localizedName ?? ""
        if app.isHidden { hiddenApps.insert(pid) }
        let observed = hub.observe(pid: pid)
        log.debug("track \(app.localizedName ?? "?", privacy: .public) pid \(pid) observed \(observed) attempt \(attempt)")
        if observed {
            reload(pid)
        } else if attempt < 20 {
            // Freshly launched apps answer Accessibility a little later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, apps[pid] != nil else { return }
                track(app, attempt: attempt + 1)
            }
        }
    }

    private func untrack(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard apps.removeValue(forKey: pid) != nil else { return }
        appNames[pid] = nil
        hiddenApps.remove(pid)
        hub.stop(pid: pid)
        windows = windows.filter { $0.value.pid != pid }
        order = order.filter { $0.key.element.pid != pid }
        firstSeen = firstSeen.filter { $0.key.element.pid != pid }
        scheduleChange()
    }

    // MARK: - Windows

    private func reload(_ pid: pid_t, attempt: Int = 0) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        guard error == .success, let list = value as? [AXUIElement] else {
            // A busy app (timeout) is not an app without windows: keep its tabs and ask again.
            log.debug("reload pid \(pid) failed: AXError \(error.rawValue), attempt \(attempt)")
            if attempt < 5, apps[pid] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reload(pid, attempt: attempt + 1) }
            }
            return
        }

        var seen = Set<ElementKey>()
        for element in list {
            let key = ElementKey(element: element)
            guard let info = read(element, pid: pid) else {
                // Timed out: keep the existing tab.
                if windows[key] != nil { seen.insert(key) }
                continue
            }
            seen.insert(key)
            let isNew = windows.updateValue(info, forKey: key) == nil
            hub.observe(window: element, pid: pid)
            if isNew { onGeometry?(info) }
        }
        windows = windows.filter { $0.value.pid != pid || seen.contains($0.key) }
        log.debug("reload pid \(pid): \(list.count) AX windows, \(seen.count) kept")
        scheduleChange()
    }

    /// Also restores a window dropped mid-transition: it keeps sending notifications.
    private func refresh(_ element: AXUIElement) {
        let key = ElementKey(element: element)
        let pid = element.pid
        guard apps[pid] != nil, let info = read(element, pid: pid) else { return }
        let old = windows.updateValue(info, forKey: key)
        if info.frame != old?.frame { onGeometry?(info) }
        scheduleChange()
    }

    private func read(_ element: AXUIElement, pid: pid_t) -> WindowInfo? {
        let v = element.values([
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
            kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
        ])
        let isMinimized = v[5] as? Bool ?? false
        // Minimized windows report AXDialog instead of AXStandardWindow (macOS 27).
        guard v[0] as? String == kAXWindowRole,
              v[1] as? String == kAXStandardWindowSubrole || isMinimized,
              let position = cgPoint(v[3]), let size = cgSize(v[4])
        else { return nil }

        let key = ElementKey(element: element)
        let rank = order[key] ?? {
            firstSeen[key] = Date()
            nextOrder += 1
            let rank = initialRank?(pid, nextOrder) ?? nextOrder
            order[key] = rank
            return rank
        }()
        return WindowInfo(
            key: key, pid: pid,
            title: v[2] as? String ?? "",
            frame: CGRect(origin: position, size: size),
            isMinimized: isMinimized,
            order: rank
        )
    }

    private func readFocus(of pid: pid_t) {
        guard let value = AXUIElementCreateApplication(pid).value(kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            focused = nil
            scheduleChange()
            return
        }
        focused = ElementKey(element: value as! AXUIElement)
        scheduleChange()
    }

    // MARK: - Notifications

    private func handle(_ name: String, _ element: AXUIElement) {
        let pid = element.pid
        switch name {
        case kAXWindowCreatedNotification:
            reload(pid)
        case kAXFocusedWindowChangedNotification:
            reload(pid)
            if pid == NSWorkspace.shared.frontmostApplication?.processIdentifier { readFocus(of: pid) }
        case kAXUIElementDestroyedNotification:
            let key = ElementKey(element: element)
            log.debug("destroyed pid \(pid) tracked \(self.windows[key] != nil)")
            hub.forget(window: key)
            order[key] = nil
            firstSeen[key] = nil
            if windows.removeValue(forKey: key) != nil { scheduleChange() }
        default:
            refresh(element)
        }
    }

    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            changeScheduled = false
            onChange?()
        }
    }
}
