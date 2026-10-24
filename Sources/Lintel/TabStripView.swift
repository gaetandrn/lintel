import AppKit
import LintelCore

struct TabItem: Equatable {
    let key: ElementKey
    let pid: pid_t
    let title: String
    let appName: String
    let isDimmed: Bool
    let isActive: Bool
    /// App-wide: set on the app's first tab only.
    let badge: String?
    let agent: AgentSummary?
    /// Pinned app: icon-only tab at the start of the bar.
    let isPinned: Bool
    let inCall: Bool
}

@MainActor
protocol TabStripDelegate: AnyObject {
    func select(_ key: ElementKey)
    func close(_ key: ElementKey)
    func closeWindowOnly(_ key: ElementKey)
    func quitApp(_ pid: pid_t)
    func reorder(_ keys: [ElementKey])
    /// Pinned tabs of one bar, in their new order after a drag: reorders the pinned apps.
    func reorderPinned(_ keys: [ElementKey])
    func icon(for pid: pid_t) -> NSImage?
    func barMenu() -> NSMenu
    func agentSessions(for pid: pid_t) -> [AgentRecord]
    func togglePin(_ pid: pid_t)
}

private enum TabStyle {
    static let font = NSFont.systemFont(ofSize: 12.5)
    static let iconSize: CGFloat = 16
    static let closeSize: CGFloat = 14
    static let padding: CGFloat = 8
    static let gap: CGFloat = 7
    static let veilHeight: CGFloat = 24
    /// Every tab gets this width, like browser tabs; all shrink together when space runs out.
    static let width: CGFloat = 200
    static let pinnedWidth: CGFloat = 32
    static let pinnedGap: CGFloat = 6
    static let minWidth: CGFloat = 90

    /// Pure white or black: labelColor is only 85% white in dark mode.
    static let text = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black }
    static let inactiveText = text.withAlphaComponent(0.61)
    static let dimmedText = text.withAlphaComponent(0.36)
}

/// One bar's tabs, drawn on the wallpaper like menu titles. Nothing animates.
final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?

    private var items: [TabItem] = []
    private var tabs: [ElementKey: TabView] = [:]
    private var visibleKeys: [ElementKey] = []
    private var pinnedKeys: [ElementKey] = []
    private let overflow = OverflowButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // One tracking area for the whole bar: per-tab areas rely on AppKit calling
        // updateTrackingAreas for each new tab, which it does not reliably do.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self
        ))
        overflow.isHidden = true
        overflow.onPick = { [unowned self] key in delegate?.select(key) }
        addSubview(overflow)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(_ items: [TabItem]) {
        guard items != self.items else { return }
        self.items = items
        layoutTabs()
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    override func menu(for event: NSEvent) -> NSMenu? { delegate?.barMenu() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    private func updateHover(_ point: NSPoint?) {
        for tab in tabs.values {
            tab.setHover(at: point.flatMap { tab.frame.contains($0) ? tab.convert($0, from: self) : nil })
        }
        overflow.setHovering(point.map { !overflow.isHidden && overflow.frame.contains($0) } ?? false)

        let hit = point.flatMap { point in
            tabs.values.lazy.compactMap { tab in tab.agentLabelFrame.flatMap { $0.contains(point) ? (tab, $0) : nil } }.first
        }
        if let (tab, frame) = hit, let pid = tab.pid, let window {
            let sessions = delegate?.agentSessions(for: pid) ?? []
            let anchor = window.convertToScreen(convert(frame, to: nil))
            SessionListPanel.shared.show(sessions, below: anchor, on: window.screen)
        } else {
            SessionListPanel.shared.hide()
        }
    }

    /// Tabs can move under a still pointer (drag, tab closed): hover follows.
    private func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(bounds.contains(point) ? point : nil)
    }

    private func layoutTabs() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var x = BarMetrics.inset
        var live = Set<ElementKey>()
        let pinned = items.filter(\.isPinned)
        let regular = items.filter { !$0.isPinned }

        pinnedKeys = pinned.map(\.key)
        for item in pinned {
            let tab = tabs[item.key] ?? makeTab(item.key)
            tab.configure(item, icon: delegate?.icon(for: item.pid))
            tab.frame = NSRect(x: x.rounded(), y: 0, width: TabStyle.pinnedWidth, height: bounds.height)
            x += TabStyle.pinnedWidth + BarMetrics.spacing
            live.insert(item.key)
        }
        if !pinned.isEmpty { x += TabStyle.pinnedGap }

        let result = TabLayout.fit(
            natural: Array(repeating: TabStyle.width, count: regular.count),
            available: bounds.width - BarMetrics.inset - x,
            minWidth: TabStyle.minWidth,
            spacing: BarMetrics.spacing,
            overflowWidth: BarMetrics.overflowWidth
        )
        visibleKeys = []
        for (item, width) in zip(regular, result.widths) {
            let tab = tabs[item.key] ?? makeTab(item.key)
            tab.configure(item, icon: delegate?.icon(for: item.pid))
            tab.frame = NSRect(x: x.rounded(), y: 0, width: width, height: bounds.height)
            x += width + BarMetrics.spacing
            visibleKeys.append(item.key)
            live.insert(item.key)
        }

        for key in tabs.keys where !live.contains(key) {
            tabs.removeValue(forKey: key)?.removeFromSuperview()
        }

        overflow.isHidden = !result.hasOverflow
        if result.hasOverflow {
            let rest = regular.dropFirst(result.widths.count)
            overflow.configure(rest.map { ($0.key, $0.title, delegate?.icon(for: $0.pid)) })
            overflow.frame = NSRect(x: x.rounded(), y: 0, width: BarMetrics.overflowWidth, height: bounds.height)
        }
        refreshHover()
    }

    /// Moves the dragged tab to the slot under the pointer, within its group (pinned or not).
    private func drag(_ key: ElementKey, toX x: CGFloat) {
        let pinned = pinnedKeys.contains(key)
        let group = pinned ? pinnedKeys : visibleKeys
        guard group.contains(key) else { return }
        let others = group.filter { $0 != key }
        let index = others.filter { other in tabs[other].map { $0.frame.midX < x } ?? false }.count
        var order = others
        order.insert(key, at: index)
        guard order != group else { return }
        if pinned { delegate?.reorderPinned(order) } else { delegate?.reorder(order) }
    }

    private func makeTab(_ key: ElementKey) -> TabView {
        let tab = TabView()
        tab.onSelect = { [unowned self] in delegate?.select(key) }
        tab.onClose = { [unowned self] in delegate?.close(key) }
        tab.onDrag = { [unowned self] event in drag(key, toX: convert(event.locationInWindow, from: nil).x) }
        tab.menuProvider = { [unowned self] item in
            let menu = NSMenu()
            menu.addItem(ActionMenuItem(L10n.closeWindow) { [weak self] in self?.delegate?.closeWindowOnly(key) })
            menu.addItem(ActionMenuItem(L10n.quitApp(item.appName)) { [weak self] in self?.delegate?.quitApp(item.pid) })
            menu.addItem(.separator())
            let pin = item.isPinned ? L10n.unpinApp(item.appName) : L10n.pinApp(item.appName)
            menu.addItem(ActionMenuItem(pin) { [weak self] in self?.delegate?.togglePin(item.pid) })
            return menu
        }
        tabs[key] = tab
        addSubview(tab)
        return tab
    }
}

// MARK: - Tab

final class TabView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var menuProvider: ((TabItem) -> NSMenu)?

    private let veil = CALayer()
    private let veilEdge = CALayer()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = CloseButton()
    private let badgeView = BadgeView()
    private let agentView = StatusPillView()
    private let callView = StatusPillView()
    /// Agent state on a pinned tab, where a label would not fit.
    private let agentDot = CALayer()
    private var item: TabItem?
    private var hovering = false {
        didSet { if hovering != oldValue { applyState() } }
    }
    private var pressOrigin: NSPoint?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        veil.cornerRadius = 6
        veil.cornerCurve = .continuous
        veil.shadowColor = NSColor.black.cgColor
        veil.shadowRadius = 1
        veil.shadowOffset = CGSize(width: 0, height: -1)
        veilEdge.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        veil.addSublayer(veilEdge)
        layer?.addSublayer(veil)
        layer?.addSublayer(agentDot)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        closeButton.onPress = { [unowned self] in onClose?() }
        closeButton.isHidden = true
        badgeView.isHidden = true
        agentView.isHidden = true
        callView.isHidden = true
        agentDot.zPosition = 10
        agentDot.cornerRadius = 4.5
        agentDot.borderWidth = 1.5
        agentDot.isHidden = true
        [iconView, label, agentView, callView, badgeView, closeButton].forEach(addSubview)
        // VoiceOver reads a tab like one of a tab view's: a selectable button named by its window.
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ item: TabItem, icon: NSImage?) {
        guard item != self.item else { return }
        if item.agent != self.item?.agent {
            agentView.pill = item.agent.map(StatusPill.agent)
            agentView.isHidden = item.agent == nil
            needsLayout = true
        }
        if item.badge != self.item?.badge || item.isPinned != self.item?.isPinned {
            badgeView.text = item.badge
            badgeView.isHidden = item.badge == nil
            badgeView.compact = item.isPinned
            needsLayout = true
        }
        if item.isPinned != self.item?.isPinned {
            label.isHidden = item.isPinned
            needsLayout = true
        }
        if item.agent != self.item?.agent || item.inCall != self.item?.inCall || item.isPinned != self.item?.isPinned {
            agentDot.isHidden = !item.isPinned || (item.agent == nil && !item.inCall)
            agentView.isHidden = item.isPinned || item.agent == nil
            callView.pill = item.inCall ? .call : nil
            callView.isHidden = item.isPinned || !item.inCall
            needsDisplay = true
            needsLayout = true
        }
        self.item = item
        label.stringValue = item.title
        iconView.image = icon
        toolTip = item.title == item.appName ? item.title : L10n.tabToolTip(app: item.appName, title: item.title)
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(item.isActive)
        applyState()
    }

    private func applyState() {
        guard let item else { return }
        let emphasized = item.isActive || hovering
        // No bold for the active tab: it stands out by full opacity and its veil.
        label.font = TabStyle.font
        label.textColor = item.isDimmed
            ? TabStyle.dimmedText
            : emphasized ? TabStyle.text : TabStyle.inactiveText
        iconView.alphaValue = item.isDimmed ? 0.45 : 1
        closeButton.isHidden = !hovering || item.isPinned
        needsDisplay = true
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // On a pinned tab's dot, a call takes precedence over agent state.
        if let color = item?.inCall == true ? StatusPillView.callColor : item?.agent.map({ StatusPillView.agentColor($0.state) }) {
            agentDot.backgroundColor = color.cgColor
            agentDot.borderColor = NSColor.white.cgColor
        }
        let active = item?.isActive == true
        let veilAlpha: CGFloat = active ? 0.2 : hovering ? 0.14 : 0
        veil.backgroundColor = NSColor.labelColor.withAlphaComponent(veilAlpha).cgColor
        veil.shadowOpacity = active ? 0.12 : 0
        veilEdge.isHidden = !active
        applyShadows()
        CATransaction.commit()
    }

    private func applyShadows() {
        let lightText = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = lightText ? NSColor.black : NSColor.white
        func shadow(blur: CGFloat, alpha: CGFloat) -> NSShadow {
            let shadow = NSShadow()
            shadow.shadowColor = color.withAlphaComponent(alpha)
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = blur
            return shadow
        }
        label.shadow = shadow(blur: 3, alpha: 0.6)
        iconView.shadow = shadow(blur: 2, alpha: 0.45)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height
        veil.frame = NSRect(x: 0, y: (h - TabStyle.veilHeight) / 2, width: bounds.width, height: TabStyle.veilHeight)
        // Inset by the corner radius so the edge stays inside the rounded corners.
        veilEdge.frame = NSRect(x: veil.cornerRadius, y: veil.isGeometryFlipped ? veil.bounds.height - 0.5 : 0, width: max(0, bounds.width - 2 * veil.cornerRadius), height: 0.5)

        let p = TabStyle.padding
        if item?.isPinned == true {
            let icon = NSRect(x: (bounds.width - TabStyle.iconSize) / 2, y: (h - TabStyle.iconSize) / 2, width: TabStyle.iconSize, height: TabStyle.iconSize)
            iconView.frame = icon
            let size = badgeView.fittingSize
            badgeView.frame = NSRect(x: icon.maxX - size.width / 2 - 1, y: icon.minY - 4, width: size.width, height: size.height)
            agentDot.frame = NSRect(x: icon.maxX - 6, y: icon.maxY - 6, width: 9, height: 9)
            CATransaction.commit()
            return
        }
        iconView.frame = NSRect(x: p, y: (h - TabStyle.iconSize) / 2, width: TabStyle.iconSize, height: TabStyle.iconSize)
        closeButton.frame = NSRect(x: bounds.width - p - TabStyle.closeSize, y: (h - TabStyle.closeSize) / 2, width: TabStyle.closeSize, height: TabStyle.closeSize)
        let labelX = iconView.frame.maxX + TabStyle.gap
        // The badge sits just left of the close button's slot, so it never moves on hover.
        var labelEnd = closeButton.frame.minX - TabStyle.gap
        if !badgeView.isHidden {
            let size = badgeView.fittingSize
            badgeView.frame = NSRect(x: labelEnd - size.width, y: (h - size.height) / 2, width: size.width, height: size.height)
            labelEnd = badgeView.frame.minX - 6
        }
        for pill in [callView, agentView] where !pill.isHidden {
            let size = pill.fittingSize
            pill.frame = NSRect(x: labelEnd - size.width, y: (h - size.height) / 2, width: size.width, height: size.height)
            labelEnd = pill.frame.minX - 6
        }
        label.frame = NSRect(x: labelX, y: (h - 16) / 2, width: max(0, labelEnd - labelX), height: 16)
        CATransaction.commit()
    }

    // The close button handles its own clicks; everything else in the tab selects it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }), bounds.contains(local) else { return nil }
        return !closeButton.isHidden && closeButton.frame.contains(local) ? closeButton : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Select on press, like browser tabs; moving past 4pt turns the press into a drag.
    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        if !dragging {
            guard abs(event.locationInWindow.x - origin.x) >= 4 else { return }
            dragging = true
            alphaValue = 0.55
        }
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
        if dragging {
            dragging = false
            alphaValue = 1
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { item.flatMap { menuProvider?($0) } }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    var pid: pid_t? { item?.pid }

    /// The agent label's frame in the strip's coordinates.
    var agentLabelFrame: NSRect? {
        if item?.isPinned == true { return agentDot.isHidden ? nil : frame }
        return agentView.isHidden ? nil : convert(agentView.frame, to: superview)
    }

    /// `point` in this tab's coordinates, nil when the pointer is elsewhere.
    func setHover(at point: NSPoint?) {
        hovering = point != nil
        closeButton.setHovering(point.map { closeButton.frame.contains($0) } ?? false)
    }
}

// MARK: - Badge

/// Red counter like the Dock's: tinted glass in a tab, a small solid pill on a pinned icon.
final class BadgeView: NSView {
    var text: String? {
        didSet { update() }
    }

    var compact = false {
        didSet { update() }
    }

    static let red = NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)

    private let glass = GlassPillView()
    private let label = NSTextField(labelWithString: "")
    private var shown: String { text.map { $0.count > 4 ? String($0.prefix(3)) + "…" : $0 } ?? "" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 8.5, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        addSubview(label)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        glass.isHidden = compact
        label.isHidden = !compact
        label.stringValue = shown
        glass.configure(text: shown, tint: Self.red, leading: .none, centered: true)
        needsDisplay = true
        needsLayout = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = compact ? Self.red.cgColor : NSColor.clear.cgColor }

    override var fittingSize: NSSize {
        guard compact else { return glass.fittingSize }
        let text = ceil(label.attributedStringValue.size().width)
        return NSSize(width: max(12, text + 6), height: 12)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        // Digits sit high in their line box: lower them so the figure is centered in the pill.
        label.frame = NSRect(x: 0, y: (bounds.height - 11) / 2 - 0.5, width: bounds.width, height: 11)
    }

    // Clicks go to the tab.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Status pill

/// What a status pill shows: a Claude Code state or a call.
enum StatusPill: Equatable {
    case agent(AgentSummary)
    case call

    var text: String {
        switch self {
        case .agent(let summary): L10n.agentSummary(summary)
        case .call: L10n.inCall
        }
    }

    var fill: NSColor {
        switch self {
        case .agent(let summary): StatusPillView.agentColor(summary.state)
        case .call: StatusPillView.callColor
        }
    }
}

/// Glass pill with a glowing dot (agents) or a phone (calls) before its label.
final class StatusPillView: GlassPillView {
    var pill: StatusPill? {
        didSet {
            guard let pill else { return }
            configure(text: pill.text, tint: pill.fill, leading: pill == .call ? .phone : .dot)
        }
    }

    private static let green = NSColor(srgbRed: 0.188, green: 0.82, blue: 0.345, alpha: 1)
    static let callColor = green

    static func agentColor(_ state: AgentState) -> NSColor {
        switch state {
        case .waiting: NSColor(srgbRed: 1, green: 0.624, blue: 0.039, alpha: 1)
        case .done: green
        case .running: NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1)
        }
    }
}

// MARK: - Close button

final class CloseButton: NSView {
    var onPress: (() -> Void)?

    private let imageView = NSImageView()
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        imageView.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.close)?.withSymbolConfiguration(config)
        imageView.contentTintColor = NSColor.labelColor.withAlphaComponent(0.8)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    func setHovering(_ value: Bool) { hovering = value }
}

// MARK: - Overflow

/// "+N" tab listing the windows that do not fit.
final class OverflowButton: NSView {
    var onPick: ((ElementKey) -> Void)?

    private let veil = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var entries: [(key: ElementKey, title: String, icon: NSImage?)] = []
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        veil.cornerRadius = 6
        layer?.addSublayer(veil)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = TabStyle.inactiveText
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        veil.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
    }

    func configure(_ entries: [(key: ElementKey, title: String, icon: NSImage?)]) {
        self.entries = entries
        label.stringValue = L10n.overflow(entries.count)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        veil.frame = NSRect(x: 0, y: (bounds.height - TabStyle.veilHeight) / 2, width: bounds.width, height: TabStyle.veilHeight)
        CATransaction.commit()
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for entry in entries {
            let item = ActionMenuItem(entry.title) { [weak self] in self?.onPick?(entry.key) }
            item.image = entry.icon.map { icon in
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                return small
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }

    func setHovering(_ value: Bool) { hovering = value }
}

/// NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.state = state
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
