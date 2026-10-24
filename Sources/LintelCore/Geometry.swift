import CoreGraphics

// Rectangles use Accessibility coordinates: origin at the top-left of the primary screen, y down.

public enum TabLayout {
    public struct Result: Equatable {
        public var widths: [CGFloat]
        public var hasOverflow: Bool
    }

    /// Tabs keep their natural width when they fit; otherwise the widest shrink first to a
    /// common cap. Tabs that would fall below `minWidth` move into an overflow tab.
    public static func fit(
        natural: [CGFloat],
        available: CGFloat,
        minWidth: CGFloat,
        spacing: CGFloat,
        overflowWidth: CGFloat
    ) -> Result {
        for n in stride(from: natural.count, through: 1, by: -1) {
            let reserve = n < natural.count ? overflowWidth + spacing : 0
            let budget = available - reserve - spacing * CGFloat(n - 1)
            let shown = natural.prefix(n)
            guard let cap = waterLevel(shown, budget: budget), cap >= minWidth else { continue }
            return Result(widths: shown.map { min($0, cap).rounded(.down) }, hasOverflow: n < natural.count)
        }
        return Result(widths: [], hasOverflow: !natural.isEmpty)
    }

    /// Largest cap such that sum(min(w, cap)) fits `budget`; infinity when everything fits.
    static func waterLevel(_ widths: ArraySlice<CGFloat>, budget: CGFloat) -> CGFloat? {
        guard budget > 0 else { return nil }
        var remaining = budget
        let sorted = widths.sorted()
        for (i, w) in sorted.enumerated() {
            let share = remaining / CGFloat(sorted.count - i)
            if w > share { return share }
            remaining -= w
        }
        return .infinity
    }
}

/// New ranks after a drag: the moved keys reuse their own ranks, so other screens are unaffected.
public func reassignedRanks<Key: Hashable>(newOrder: [Key], ranks: [Key: Int]) -> [Key: Int]? {
    let values = newOrder.compactMap { ranks[$0] }.sorted()
    guard values.count == newOrder.count else { return nil }
    return Dictionary(uniqueKeysWithValues: zip(newOrder, values))
}

public func screenIndex(for rect: CGRect, screens: [CGRect]) -> Int? {
    var best: (index: Int, area: CGFloat)?
    for (i, screen) in screens.enumerated() {
        let r = rect.intersection(screen)
        guard !r.isNull else { continue }
        let area = r.width * r.height
        if area > (best?.area ?? 0) { best = (i, area) }
    }
    return best?.index
}

/// True when `window` covers the screen below `contentTop` (the notch); maximized windows never do.
public func isFullScreen(window: CGRect, screen: CGRect, contentTop: CGFloat) -> Bool {
    window.minX <= screen.minX + 0.5 && window.maxX >= screen.maxX - 0.5
        && window.minY <= contentTop + 0.5 && window.maxY >= screen.maxY - 0.5
}

public enum CloseAction: Equatable {
    case closeWindow
    case quitApp
}

/// Closing the last window quits the app (⌘Q), except for apps that must not quit.
public func closeAction(windowCountForApp: Int, bundleID: String?) -> CloseAction {
    if windowCountForApp > 1 || bundleID.map(neverQuitBundleIDs.contains) == true {
        return .closeWindow
    }
    return .quitApp
}

public let neverQuitBundleIDs: Set<String> = ["com.apple.finder"]

/// Frame moving `window` below the bar (sliding down, else shrinking), or nil if it doesn't overlap.
public func frameClearingBar(window: CGRect, barBottom: CGFloat, visibleBottom: CGFloat) -> CGRect? {
    guard window.minY < barBottom - 0.5 else { return nil }
    if barBottom + window.height <= visibleBottom + 0.5 {
        return CGRect(x: window.minX, y: barBottom, width: window.width, height: window.height)
    }
    return CGRect(x: window.minX, y: barBottom, width: window.width, height: min(window.maxY, visibleBottom) - barBottom)
}

/// Merges the current app order into the saved one: closed apps keep their slots, new ones go last.
public func mergedAppOrder(saved: [String], current: [String]) -> [String] {
    var result = saved + current.filter { !saved.contains($0) }
    let open = Set(current)
    let slots = result.indices.filter { open.contains(result[$0]) }
    for (slot, app) in zip(slots, current) { result[slot] = app }
    return result
}

/// Starting rank of a window: its app's saved position, then discovery order. Apps are
/// 100_000 ranks apart, more windows than a session discovers, so an app's windows never
/// sort past the next app's.
public func initialRank(appIndex: Int?, knownApps: Int, sequence: Int) -> Int {
    (appIndex ?? knownApps) * 100_000 + sequence
}
