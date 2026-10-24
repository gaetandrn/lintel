import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "io.github.gaetandrn.lintel", category: "titleBarZoom")

/// Double-clicking a window's title bar fits the window below the bar instead of
/// letting macOS zoom it over the bar; a second double-click restores it.
/// Expects macOS's own action to be off (see `SystemTitleBarDoubleClick`).
@MainActor
final class TitleBarZoom {
    /// Installs or removes the event tap; nothing runs while disabled.
    /// Falls back to false when the event tap can't be created.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { uninstall() } else if !install() { isEnabled = false }
        }
    }

    /// Frame states a window can be toggled between, in AX coordinates.
    struct Entry: Equatable {
        /// Frame before the zoom, to restore.
        var restore: CGRect
        /// Frame the window actually took: apps with size steps or limits stop short of the target.
        var applied: CGRect
    }

    enum Decision: Equatable {
        case zoom
        case restore(CGRect)
        case none
    }

    /// Title bar plus a unified toolbar.
    private static let stripHeight: CGFloat = 52
    private static let tolerance: CGFloat = 2
    private static let maxEntries = 50

    private let targetFrame: (CGRect) -> CGRect?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var entries: [ElementKey: Entry] = [:]
    /// Insertion order of `entries`, oldest first.
    private var order: [ElementKey] = []

    /// `targetFrame` gives the frame (AX coordinates) a window with the given frame should fill.
    init(targetFrame: @escaping (CGRect) -> CGRect?) {
        self.targetFrame = targetFrame
    }

    // MARK: - Event tap

    private func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("event tap could not be created")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        return true
    }

    private func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        entries = [:]
        order = []
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func doubleClicked(at point: CGPoint) {
        guard isEnabled, let window = titleBarWindow(at: point) else { return }
        let key = ElementKey(element: window)
        guard let frame = window.frame else { return forget(key) }
        guard let target = targetFrame(frame) else { return }
        switch Self.decide(current: frame, target: target, entry: entries[key]) {
        case .zoom:
            window.setFrame(target)
            remember(key, Entry(restore: frame, applied: window.frame ?? target))
        case .restore(let previous):
            window.setFrame(previous)
            forget(key)
        case .none:
            break
        }
    }

    // MARK: - Hit testing

    /// The standard window whose title bar is at `point`, if the click landed on
    /// its title bar or toolbar background rather than on a control.
    private func titleBarWindow(at point: CGPoint) -> AXUIElement? {
        // Lintel's own windows: a hit test there would message this (busy) main thread.
        if isOwnWindow(at: point) { return nil }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, hit.pid != getpid()
        else { return nil }

        let info = hit.values([kAXRoleAttribute, kAXSubroleAttribute, kAXWindowAttribute])
        let role = info[0] as? String
        let subrole = info[1] as? String
        guard let window = Self.window(of: hit, role: role, subrole: subrole, windowValue: info[2]) else { return nil }

        let attributes = window.values([kAXSubroleAttribute, "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute])
        guard attributes[0] as? String == kAXStandardWindowSubrole,
              (attributes[1] as? Bool) != true,
              let position = cgPoint(attributes[2]), let size = cgSize(attributes[3]),
              Self.isInTitleStrip(point, window: CGRect(origin: position, size: size)),
              CFEqual(hit, window) || !Self.isControl(role: role, subrole: subrole) || isToolbarSpacer(hit, role: role),
              isResizable(window)
        else { return nil }
        return window
    }

    private func isOwnWindow(at point: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let cocoa = NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        let number = NSWindow.windowNumber(at: cocoa, belowWindowWithWindowNumber: 0)
        return NSApp.windows.contains { $0.windowNumber == number }
    }

    private static func window(of element: AXUIElement, role: String?, subrole: String?, windowValue: CFTypeRef?) -> AXUIElement? {
        // Some apps (Emacs) expose the window as another role with the window's subrole.
        if role == kAXWindowRole || subrole == kAXStandardWindowSubrole { return element }
        if let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            return (windowValue as! AXUIElement)
        }
        var current = element
        for _ in 0..<16 {
            guard let parent = current.value(kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
            if current.value(kAXRoleAttribute) as? String == kAXWindowRole { return current }
        }
        return nil
    }

    /// Some toolkits lay out empty toolbar space as a splitter; a real divider elsewhere keeps its clicks.
    private func isToolbarSpacer(_ element: AXUIElement, role: String?) -> Bool {
        guard role == kAXSplitterRole,
              let parent = element.value(kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID()
        else { return false }
        return (parent as! AXUIElement).value(kAXRoleAttribute) as? String == kAXToolbarRole
    }

    /// Fixed-size windows (their zoom button is disabled) would only be moved.
    private func isResizable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    // MARK: - Rules

    /// Roles that keep their own double-click (editing, selecting, pressing).
    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXComboBoxRole, kAXTextFieldRole, kAXTextAreaRole, kAXRadioGroupRole, kAXSliderRole,
        kAXIncrementorRole, kAXColorWellRole, kAXDisclosureTriangleRole, kAXSplitterRole,
        kAXTableRole, kAXOutlineRole, kAXRowRole, kAXCellRole, kAXListRole, kAXScrollAreaRole,
        kAXMenuBarRole, kAXMenuItemRole, kAXValueIndicatorRole,
        "AXSegmentedControl", "AXTab", "AXLink", "AXWebArea", "AXSearchField", "AXDateField",
    ]
    private static let controlSubroles: Set<String> = [
        kAXSearchFieldSubrole, kAXSecureTextFieldSubrole, "AXTabButton", kAXCloseButtonSubrole,
        kAXMinimizeButtonSubrole, kAXZoomButtonSubrole, kAXFullScreenButtonSubrole,
    ]

    /// Whether an element with this role takes double-clicks itself. The window,
    /// toolbar, groups, the title text and unknown elements do not.
    static func isControl(role: String?, subrole: String?) -> Bool {
        if let role, controlRoles.contains(role) { return true }
        if let subrole, controlSubroles.contains(subrole) { return true }
        return false
    }

    static func isInTitleStrip(_ point: CGPoint, window: CGRect) -> Bool {
        window.contains(point) && point.y - window.minY <= stripHeight
    }

    /// Zooms unless the window already fills the target (or the frame it settled
    /// at last time), in which case it goes back to where it was.
    static func decide(current: CGRect, target: CGRect, entry: Entry?) -> Decision {
        let zoomed = matches(current, target) || entry.map { matches(current, $0.applied) } == true
        guard zoomed else { return .zoom }
        guard let entry, !matches(entry.restore, current) else { return .none }
        return .restore(entry.restore)
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    // MARK: - Memory

    private func remember(_ key: ElementKey, _ entry: Entry) {
        if entries.updateValue(entry, forKey: key) != nil { order.removeAll { $0 == key } }
        order.append(key)
        // Closed windows are never told apart cheaply: the oldest go first.
        while order.count > Self.maxEntries { entries[order.removeFirst()] = nil }
    }

    private func forget(_ key: ElementKey) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }
}

private func tapCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let zoom = Unmanaged<TitleBarZoom>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { zoom.reenable() }
    case .leftMouseUp where event.getIntegerValueField(.mouseEventClickState) == 2:
        // Already top-left, like AX. Hit testing waits on other apps: leave the tap first.
        let location = event.location
        DispatchQueue.main.async {
            MainActor.assumeIsolated { zoom.doubleClicked(at: location) }
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

/// macOS's own "double-click a window's title bar" action (`AppleActionOnDoubleClick`
/// in the global domain): "Maximize" (the default), "Minimize" or "None".
enum SystemTitleBarDoubleClick {
    static let none = "None"
    private static let key = "AppleActionOnDoubleClick" as CFString

    /// nil when the user never changed it.
    static var action: String? {
        get {
            CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        }
        set {
            CFPreferencesSetValue(key, newValue as CFString?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }
}
