import AppKit

enum BarMetrics {
    /// Keep in sync with BAR_HEIGHT in install.sh.
    static let height: CGFloat = 28
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 2
    static let overflowWidth: CGFloat = 40
}

/// A screen and where its bar sits, in both coordinate spaces.
struct BarScreen {
    let id: CGDirectDisplayID
    let screen: NSScreen
    /// Cocoa coordinates (bottom-left origin).
    let barFrame: NSRect
    /// Accessibility coordinates (top-left origin).
    let frameAX: CGRect
    let barBottomAX: CGFloat
    let visibleBottomAX: CGFloat
    /// Top of the usable area (below the notch), where a full-screen window starts.
    let contentTopAX: CGFloat

    static func all() -> [BarScreen] {
        guard let primary = NSScreen.screens.first else { return [] }
        let top = primary.frame.maxY
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            let visible = screen.visibleFrame
            let barY = visible.maxY - BarMetrics.height
            return BarScreen(
                id: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0,
                screen: screen,
                barFrame: NSRect(x: frame.minX, y: barY, width: frame.width, height: BarMetrics.height),
                frameAX: CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height),
                barBottomAX: top - barY,
                visibleBottomAX: top - visible.minY,
                contentTopAX: top - frame.maxY + screen.safeAreaInsets.top
            )
        }
    }
}

/// Transparent, non-activating panel holding one screen's tab strip.
final class BarPanel: NSPanel {
    let strip = TabStripView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // isFloatingPanel resets the level to .floating: set it first.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        // Fully transparent pixels pass clicks through; a near-invisible tint keeps them all.
        backgroundColor = NSColor(white: 0, alpha: 0.004)
        ignoresMouseEvents = false

        strip.autoresizingMask = [.width, .height]
        contentView = strip
    }

    func setLightText(_ light: Bool) {
        let target = NSAppearance(named: light ? .darkAqua : .aqua)
        if appearance?.name != target?.name { appearance = target }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(_ screen: BarScreen) {
        setFrame(screen.barFrame, display: false)
    }

    /// Hides the bar over full-screen apps: the panel joins every Space, full-screen ones included.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        if visible { orderFrontRegardless() } else { orderOut(nil) }
    }
}
