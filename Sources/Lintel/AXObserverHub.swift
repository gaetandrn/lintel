import ApplicationServices

/// One AXObserver per app, delivering notifications on the main run loop.
@MainActor
final class AXObserverHub {
    var handler: ((_ notification: String, _ element: AXUIElement) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var registered = Set<ElementKey>()

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Returns false when the app does not answer Accessibility yet (still launching).
    @discardableResult
    func observe(pid: pid_t) -> Bool {
        if observers[pid] != nil { return true }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return false }

        let app = AXUIElementCreateApplication(pid)
        let results = Self.appNotifications.map { AXObserverAddNotification(observer, app, $0 as CFString, refcon) }
        guard results.contains(where: { $0 == .success || $0 == .notificationAlreadyRegistered }) else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        return true
    }

    func observe(window: AXUIElement, pid: pid_t) {
        let key = ElementKey(element: window)
        guard let observer = observers[pid], !registered.contains(key) else { return }
        let results = Self.windowNotifications.map { AXObserverAddNotification(observer, window, $0 as CFString, refcon) }
        // A busy app times out: leave the window unregistered so the next reload tries again.
        if results.contains(where: { $0 == .success || $0 == .notificationAlreadyRegistered }) {
            registered.insert(key)
        }
    }

    /// AX drops a destroyed window's registrations by itself.
    func forget(window key: ElementKey) {
        registered.remove(key)
    }

    func stop(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        registered = registered.filter { $0.element.pid != pid }
    }

    fileprivate func deliver(_ notification: String, _ element: AXUIElement) {
        handler?(notification, element)
    }
}

private func axCallback(_: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let hub = Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { hub.deliver(notification as String, element) }
}
