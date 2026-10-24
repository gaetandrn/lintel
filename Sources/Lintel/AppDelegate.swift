import AppKit
import ApplicationServices
import OSLog
import ServiceManagement
import LintelCore

private let log = Logger(subsystem: "io.github.gaetandrn.lintel", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = WindowStore()
    private let overlapGuard = OverlapGuard()
    private let badgeMonitor = BadgeMonitor()
    private let agentMonitor = AgentMonitor()
    private let callMonitor = CallMonitor()
    private lazy var titleBarZoom = TitleBarZoom { [unowned self] frame in fillFrame(for: frame) }
    private var screens: [BarScreen] = []
    private var panels: [CGDirectDisplayID: BarPanel] = [:]
    private var icons: [pid_t: NSImage] = [:]
    private var permissionTimer: Timer?
    /// Invisible zero-length status item: its button takes the menu bar's appearance, which
    /// macOS picks from the wallpaper. Only exists while the text tone is "auto".
    private var menuBarProbe: NSStatusItem?
    private var menuBarObservation: NSKeyValueObservation?
    /// Why polling is paused: screens asleep, another user's session in front.
    private var pauseReasons = Set<Notification.Name>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch arguments used by install.sh and uninstall.sh.
        let arguments = CommandLine.arguments
        if arguments.contains("--unregister-login-item") {
            launchAtLogin = false
            exit(0)
        }
        if arguments.contains("--launch-at-login"), !launchAtLogin {
            launchAtLogin = true
        }
        if arguments.contains("--title-bar-zoom") {
            titleBarZoomEnabled = true
        }
        if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            start()
            return
        }
        // macOS posts nothing when Accessibility is granted: poll until it is.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if titleBarZoomEnabled { handleSystemTitleBarDoubleClick(false) }
    }

    private func start() {
        rebuildBars()
        titleBarZoom.isEnabled = titleBarZoomEnabled
        // Without the event tap, macOS keeps its own action.
        handleSystemTitleBarDoubleClick(titleBarZoom.isEnabled)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildBars()
                self?.render()
            }
        }

        store.initialRank = { [unowned self] pid, sequence in
            let saved = appOrder
            let index = store.apps[pid]?.bundleIdentifier.flatMap { saved.firstIndex(of: $0) }
            return initialRank(appIndex: index, knownApps: saved.count, sequence: sequence)
        }
        store.onChange = { [unowned self] in
            rememberAppOrder()
            // Call windows open and close with the window list; moves don't matter.
            let keys = Set(store.windows.keys)
            if keys != lastWindowKeys {
                lastWindowKeys = keys
                callMonitor.windowsChanged()
            }
            render()
        }
        store.onGeometry = { [unowned self] in overlapGuard.check($0) }
        overlapGuard.start { [unowned self] in store.focused.flatMap { store.windows[$0] } }
        badgeMonitor.onChange = { [unowned self] in render() }
        badgeMonitor.start { [unowned self] in store.apps }
        agentMonitor.onChange = { [unowned self] in render() }
        agentMonitor.start { [unowned self] in store.apps }
        callMonitor.onChange = { [unowned self] in render() }
        callMonitor.start { [unowned self] in store.apps }
        store.start()

        // Nobody sees the bar while the screens sleep or another user is in front: stop polling.
        let pauses = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (pause, resume) in pauses {
            NSWorkspace.shared.notificationCenter.addObserver(forName: pause, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(pause, true) }
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(pause, false) }
            }
        }
    }

    private func setPaused(_ reason: Notification.Name, _ paused: Bool) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        badgeMonitor.isPaused = !pauseReasons.isEmpty
        callMonitor.isPaused = !pauseReasons.isEmpty
    }

    // MARK: - Bars

    private func rebuildBars() {
        screens = BarScreen.all()
        overlapGuard.screens = screens
        let ids = Set(screens.map(\.id))
        for (id, panel) in panels where !ids.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for screen in screens {
            let panel = panels[screen.id] ?? {
                let panel = BarPanel()
                panel.strip.delegate = self
                panels[screen.id] = panel
                return panel
            }()
            panel.place(screen)
        }
        refreshTextTone()
    }

    /// Light or dark text like the menu bar's, which macOS updates as the wallpaper changes.
    private func refreshTextTone() {
        let tone = textTone
        let light: Bool
        switch tone {
        case "light", "dark":
            light = tone == "light"
            menuBarObservation = nil
            if let probe = menuBarProbe { NSStatusBar.system.removeStatusItem(probe) }
            menuBarProbe = nil
        default:
            if menuBarProbe == nil {
                let probe = NSStatusBar.system.statusItem(withLength: 0)
                menuBarObservation = probe.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refreshTextTone() }
                }
                menuBarProbe = probe
            }
            // The menu bar has one appearance for all screens, even when their wallpapers differ.
            let appearance = menuBarProbe?.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            light = appearance == .darkAqua || appearance == .vibrantDark
        }
        for panel in panels.values { panel.setLightText(light) }
    }

    private var lastWindowKeys = Set<ElementKey>()
    private var fullScreen = Set<CGDirectDisplayID>()
    private var lastFullScreenCheck = Date.distantPast
    private var fullScreenCheckScheduled = false

    private func refreshFullScreen() {
        // Listing on-screen windows is too costly for every render during a drag: throttle it,
        // with a trailing check so a switch to full screen is never missed.
        let elapsed = Date().timeIntervalSince(lastFullScreenCheck)
        if elapsed >= 0.3 {
            lastFullScreenCheck = Date()
            fullScreen = fullScreenDisplays()
        } else if !fullScreenCheckScheduled {
            fullScreenCheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 - elapsed) { [weak self] in
                guard let self else { return }
                fullScreenCheckScheduled = false
                render()
            }
        }
    }

    private func render() {
        guard !screens.isEmpty else { return }
        refreshFullScreen()
        for screen in screens {
            panels[screen.id]?.setVisible(!fullScreen.contains(screen.id))
        }

        let frames = screens.map(\.frameAX)
        var perScreen = Array(repeating: [WindowInfo](), count: screens.count)
        for window in store.windows.values {
            // Off-screen windows (e.g. minimized with no frame) go to the main screen.
            perScreen[screenIndex(for: window.frame, screens: frames) ?? 0].append(window)
        }
        // Badges and agent states belong to the app: show them once, on its first tab.
        var badgedTab: [pid_t: ElementKey] = [:]
        for window in store.windows.values.sorted(by: { $0.order < $1.order }) where badgedTab[window.pid] == nil {
            badgedTab[window.pid] = window.key
        }
        func isCall(_ window: WindowInfo) -> Bool {
            callMonitor.callTitles[window.pid].map { $0 == window.title } ?? false
        }
        // Pinned apps come first, in pin order. A call window is never pinned, so it keeps a
        // full tab with its label while the app's main window stays pinned.
        let pins = pinnedApps
        func pinIndex(_ window: WindowInfo) -> Int? {
            guard !isCall(window) else { return nil }
            return store.apps[window.pid]?.bundleIdentifier.flatMap { pins.firstIndex(of: $0) }
        }
        for (screen, windows) in zip(screens, perScreen) {
            let sorted = windows.sorted { a, b in
                let (pa, pb) = (pinIndex(a) ?? .max, pinIndex(b) ?? .max)
                return pa != pb ? pa < pb : a.order < b.order
            }
            let items = sorted.map { window in
                let appName = store.appNames[window.pid] ?? ""
                return TabItem(
                    key: window.key,
                    pid: window.pid,
                    title: window.title.isEmpty ? appName : window.title,
                    appName: appName,
                    isDimmed: window.isMinimized || store.hiddenApps.contains(window.pid),
                    isActive: window.key == store.focused,
                    badge: badgedTab[window.pid] == window.key ? badgeMonitor.badges[window.pid] : nil,
                    agent: badgedTab[window.pid] == window.key ? agentMonitor.summary(for: window.pid) : nil,
                    isPinned: pinIndex(window) != nil,
                    inCall: isCall(window)
                )
            }
            panels[screen.id]?.strip.update(items)
        }
        icons = icons.filter { store.apps[$0.key] != nil }
    }

    private func fullScreenDisplays() -> Set<CGDirectDisplayID> {
        var displays = Set<CGDirectDisplayID>()
        if let key = store.focused, key.element.bool("AXFullScreen"), let frame = key.element.frame,
           let index = screenIndex(for: frame, screens: screens.map(\.frameAX)) {
            displays.insert(screens[index].id)
        }

        // Window bounds need no Screen Recording permission; only titles do.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return displays }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != ownPID,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { continue }
            for screen in screens where isFullScreen(window: bounds, screen: screen.frameAX, contentTop: screen.contentTopAX) {
                displays.insert(screen.id)
            }
        }
        return displays
    }

    // MARK: - Settings

    /// Order of apps in the bar, by bundle id: windows have no identity across launches.
    private var appOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "appOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "appOrder") }
    }

    private func rememberAppOrder() {
        var current: [String] = []
        for window in store.windows.values.sorted(by: { $0.order < $1.order }) {
            if let id = store.apps[window.pid]?.bundleIdentifier, !current.contains(id) { current.append(id) }
        }
        let merged = mergedAppOrder(saved: appOrder, current: current)
        if merged != appOrder { appOrder = merged }
    }

    private var pinnedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: "pinnedApps") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedApps") }
    }

    /// "auto" (like the menu bar), "light" or "dark".
    private var textTone: String {
        get { UserDefaults.standard.string(forKey: "textTone") ?? "auto" }
        set {
            UserDefaults.standard.set(newValue, forKey: "textTone")
            refreshTextTone()
        }
    }

    /// Lintel handles title-bar double-clicks itself (uninstall.sh reads the saved value too).
    private var titleBarZoomEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "titleBarZoom") }
        set {
            guard newValue != titleBarZoomEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: "titleBarZoom")
            guard AXIsProcessTrusted() else { return }
            titleBarZoom.isEnabled = newValue
            handleSystemTitleBarDoubleClick(titleBarZoom.isEnabled)
        }
    }

    /// macOS's own action is None only while Lintel handles the double-click: it is restored
    /// when Lintel quits, and uninstall.sh restores it otherwise.
    private func handleSystemTitleBarDoubleClick(_ handled: Bool) {
        let defaults = UserDefaults.standard
        if handled {
            // Saved once ("" when macOS had no value): after a crash, "None" is never saved over it.
            if defaults.string(forKey: "previousTitleBarDoubleClick") == nil {
                defaults.set(SystemTitleBarDoubleClick.action ?? "", forKey: "previousTitleBarDoubleClick")
            }
            SystemTitleBarDoubleClick.action = SystemTitleBarDoubleClick.none
        } else if let previous = defaults.string(forKey: "previousTitleBarDoubleClick") {
            SystemTitleBarDoubleClick.action = previous.isEmpty ? nil : previous
            defaults.removeObject(forKey: "previousTitleBarDoubleClick")
        }
    }

    /// The area a window fills on a title-bar double-click: below the bar, beside a side Dock, above the Dock.
    private func fillFrame(for window: CGRect) -> CGRect? {
        guard let index = screenIndex(for: window, screens: screens.map(\.frameAX)) else { return nil }
        let screen = screens[index]
        let visible = screen.screen.visibleFrame
        return CGRect(x: visible.minX, y: screen.barBottomAX, width: visible.width, height: screen.visibleBottomAX - screen.barBottomAX)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// One request to GitHub, only when asked from the menu.
    private func checkForUpdates() {
        let url = URL(string: "https://api.github.com/repos/gaetandrn/lintel/releases/latest")!
        URLSession.shared.dataTask(with: url) { data, response, _ in
            // An error page or a rate limit is "couldn't check", never "up to date".
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let latest = data
                .flatMap { ok ? try? JSONSerialization.jsonObject(with: $0) as? [String: Any] : nil }
                .flatMap { $0["tag_name"] as? String }
                .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
                .flatMap { $0.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil ? $0 : nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.showUpdateResult(latest: latest) }
            }
        }.resume()
    }

    /// The install command from the README: it updates in place.
    private static let updateCommand = "curl -fsSL https://github.com/gaetandrn/lintel/releases/latest/download/install.sh | bash"

    private func showUpdateResult(latest: String?) {
        let alert = NSAlert()
        let available = latest.map { $0.compare(version, options: .numeric) == .orderedDescending } ?? false
        if let latest, available {
            alert.messageText = L10n.updateAvailable(latest)
            alert.informativeText = L10n.updateAvailableMessage(current: version)
            alert.addButton(withTitle: L10n.updateCopyCommand)
            alert.addButton(withTitle: L10n.updateLater)
        } else {
            alert.messageText = latest == nil ? L10n.updateFailed : L10n.upToDate
            alert.addButton(withTitle: L10n.ok)
        }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, available {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.updateCommand, forType: .string)
        }
    }

    private var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("launch at login: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension AppDelegate: TabStripDelegate {
    func select(_ key: ElementKey) {
        guard let window = store.windows[key], let app = store.apps[window.pid] else { return }
        store.markFocused(key)
        WindowActions.activate(window, app: app)
    }

    func close(_ key: ElementKey) {
        guard let window = store.windows[key], let app = store.apps[window.pid] else { return }
        switch closeAction(windowCountForApp: store.windowCount(pid: window.pid), bundleID: app.bundleIdentifier) {
        case .closeWindow: WindowActions.close(window)
        case .quitApp: app.terminate()
        }
    }

    func closeWindowOnly(_ key: ElementKey) {
        store.windows[key].map(WindowActions.close)
    }

    func quitApp(_ pid: pid_t) {
        store.apps[pid]?.terminate()
    }

    func reorder(_ keys: [ElementKey]) {
        store.reorder(keys)
    }

    func reorderPinned(_ keys: [ElementKey]) {
        // Apps in the order of their first icon; pinned apps not on this bar keep their slot.
        var apps: [String] = []
        for key in keys {
            if let pid = store.windows[key]?.pid, let id = store.apps[pid]?.bundleIdentifier, !apps.contains(id) { apps.append(id) }
        }
        pinnedApps = mergedAppOrder(saved: pinnedApps, current: apps)
        store.reorder(keys)
        render()
    }

    func agentSessions(for pid: pid_t) -> [AgentRecord] {
        agentMonitor.sessions(for: pid)
    }

    func togglePin(_ pid: pid_t) {
        guard let bundleID = store.apps[pid]?.bundleIdentifier else { return }
        if let index = pinnedApps.firstIndex(of: bundleID) {
            pinnedApps.remove(at: index)
        } else {
            pinnedApps.append(bundleID)
        }
        render()
    }

    func icon(for pid: pid_t) -> NSImage? {
        if let icon = icons[pid] { return icon }
        let icon = store.apps[pid]?.icon
        icons[pid] = icon
        return icon
    }

    func barMenu() -> NSMenu {
        let menu = NSMenu()
        let versionItem = NSMenuItem(title: L10n.version(version), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L10n.openAtLogin, state: launchAtLogin ? .on : .off) { [weak self] in
            guard let self else { return }
            launchAtLogin.toggle()
        })
        menu.addItem(ActionMenuItem(L10n.keepWindowsBelowBar, state: overlapGuard.isEnabled ? .on : .off) { [weak self] in
            guard let self else { return }
            overlapGuard.isEnabled.toggle()
        })
        menu.addItem(ActionMenuItem(L10n.titleBarZoom, state: titleBarZoomEnabled ? .on : .off) { [weak self] in
            guard let self else { return }
            titleBarZoomEnabled.toggle()
        })
        let tone = NSMenuItem(title: L10n.textColor, action: nil, keyEquivalent: "")
        tone.submenu = NSMenu()
        for (value, title) in [("auto", L10n.textColorAutomatic), ("light", L10n.textColorLight), ("dark", L10n.textColorDark)] {
            tone.submenu?.addItem(ActionMenuItem(title, state: textTone == value ? .on : .off) { [weak self] in self?.textTone = value })
        }
        menu.addItem(tone)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L10n.checkForUpdates) { [weak self] in self?.checkForUpdates() })
        menu.addItem(ActionMenuItem(L10n.quitLintel) { NSApp.terminate(nil) })
        return menu
    }
}
