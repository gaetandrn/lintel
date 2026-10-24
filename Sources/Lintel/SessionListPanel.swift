import AppKit
import LintelCore

/// Lists an app's Claude Code sessions under its hovered agent label.
@MainActor
final class SessionListPanel {
    static let shared = SessionListPanel()

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private var shownRows: [String] = []

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        panel.contentView = background
    }

    func show(_ sessions: [AgentRecord], below anchor: NSRect, on screen: NSScreen?) {
        guard !sessions.isEmpty else { return hide() }
        let now = Date()
        let rows = sessions.map { session in
            [project(of: session), L10n.agentState(session.state), L10n.duration(minutes: agentMinutesInState(since: session.since, now: now))]
        }
        let signature = rows.map { $0.joined(separator: "|") }
        if signature != shownRows || !panel.isVisible {
            shownRows = signature
            build(rows, states: sessions.map(\.state))
        }

        let size = panel.frame.size
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.minY - 6 - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// The hook already resolves the git repository: reading the folder here would make
    /// macOS ask for Documents or Desktop access.
    private func project(of session: AgentRecord) -> String {
        guard let cwd = session.cwd else { return L10n.untitledSession }
        return (cwd as NSString).lastPathComponent
    }

    private func build(_ rows: [[String]], states: [AgentState]) {
        let grid = NSGridView(views: zip(rows, states).map { row, state in
            [Self.dot(state), Self.text(row[0], weight: .semibold), Self.text(row[1]), Self.text(row[2], secondary: true)]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .center
        grid.yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = true

        let size = grid.fittingSize
        let padding = NSSize(width: 12, height: 9)
        grid.frame = NSRect(x: padding.width, y: padding.height, width: size.width, height: size.height)
        background.subviews = [grid]
        panel.setContentSize(NSSize(width: size.width + 2 * padding.width, height: size.height + 2 * padding.height))
    }

    private static func text(_ string: String, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: 12, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private static func dot(_ state: AgentState) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        view.layer?.backgroundColor = StatusPillView.agentColor(state).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 8), view.heightAnchor.constraint(equalToConstant: 8)])
        return view
    }
}
