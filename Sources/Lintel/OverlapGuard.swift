import AppKit
import LintelCore

/// Moves windows out from under the bar, e.g. after an app restores its frame.
@MainActor
final class OverlapGuard {
    var screens: [BarScreen] = []

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    private static let defaultsKey = "overlapGuard"
    /// Zooms and resizes arrive in steps; a correction mid-way would be overwritten.
    private static let settleDelay = 0.05
    private var pending: [ElementKey: DispatchWorkItem] = [:]
    /// Corrections per window in the current 1 s span: an app that snaps its window back
    /// under the bar would otherwise be corrected forever.
    private var recent: [ElementKey: (start: Date, count: Int)] = [:]
    private static let maxCorrections = 3
    private var mouseUpMonitor: Any?

    func start(focusedWindow: @escaping () -> WindowInfo?) {
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = focusedWindow() else { return }
                self.check(window)
            }
        }
    }

    func check(_ window: WindowInfo, attempt: Int = 0) {
        guard isEnabled, !window.isMinimized else { return }
        pending[window.key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pending[window.key] = nil
            correct(window, attempt: attempt)
        }
        pending[window.key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func correct(_ window: WindowInfo, attempt: Int) {
        // Never fight a drag in progress: the mouse-up monitor catches the drop.
        guard NSEvent.pressedMouseButtons == 0,
              let frame = window.element.frame,
              let index = screenIndex(for: frame, screens: screens.map(\.frameAX))
        else { return }
        let screen = screens[index]
        guard let target = frameClearingBar(window: frame, barBottom: screen.barBottomAX, visibleBottom: screen.visibleBottomAX),
              !window.element.bool("AXFullScreen")
        else { return }
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value.start) < 1 }
        let count = recent[window.key]?.count ?? 0
        guard count < Self.maxCorrections else { return }
        recent[window.key] = (recent[window.key]?.start ?? now, count + 1)
        window.element.setFrame(target)
        // Some apps apply their own frame right after ours: look once more.
        if attempt == 0 { check(window, attempt: 1) }
    }
}
