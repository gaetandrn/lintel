import CoreGraphics
import Testing
@testable import LintelCore

struct TabLayoutTests {
    func fit(_ natural: [CGFloat], _ available: CGFloat) -> TabLayout.Result {
        TabLayout.fit(natural: natural, available: available, minWidth: 90, spacing: 2, overflowWidth: 40)
    }

    func used(_ r: TabLayout.Result) -> CGFloat {
        r.widths.reduce(0, +) + 2 * CGFloat(max(0, r.widths.count - 1)) + (r.hasOverflow ? 42 : 0)
    }

    @Test func empty() {
        #expect(fit([], 1000) == .init(widths: [], hasOverflow: false))
    }

    @Test func naturalWidthsWhenTheyFit() {
        #expect(fit([120, 200, 90], 1000) == .init(widths: [120, 200, 90], hasOverflow: false))
    }

    @Test func widestShrinkFirst() {
        // 100 + 2 + 400 + 2 + 400 = 904 > 600: the two long ones share what is left.
        let r = fit([100, 400, 400], 600)
        #expect(r == .init(widths: [100, 248, 248], hasOverflow: false))
        #expect(used(r) <= 600)
    }

    @Test func equalTabsShrinkTogether() {
        // Browser-like: same width for all, (400 - 2 × 2) / 3 = 132.
        #expect(fit([200, 200, 200], 400) == .init(widths: [132, 132, 132], hasOverflow: false))
    }

    @Test func overflowBelowMinWidth() {
        let r = fit(Array(repeating: 200, count: 20), 1000)
        #expect(r.hasOverflow)
        #expect(r.widths.count == 10) // 10 × 90 + 9 × 2 + 42 = 960
        #expect(r.widths.allSatisfy { $0 >= 90 })
        #expect(used(r) <= 1000)
    }

    @Test func narrowerThanOneTabShowsOnlyTheOverflow() {
        #expect(fit([200], 50) == .init(widths: [], hasOverflow: true))
        #expect(fit([200, 200], 50) == .init(widths: [], hasOverflow: true))
    }
}

struct ReorderTests {
    @Test func movedKeysSwapRanks() {
        let ranks = ["a": 1, "b": 3, "c": 7, "other": 5]
        let result = reassignedRanks(newOrder: ["c", "a", "b"], ranks: ranks)
        #expect(result == ["c": 1, "a": 3, "b": 7])
    }

    @Test func unknownKeyAborts() {
        #expect(reassignedRanks(newOrder: ["a", "zzz"], ranks: ["a": 1]) == nil)
    }
}

struct ScreenIndexTests {
    let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]

    @Test func picksLargestOverlap() {
        #expect(screenIndex(for: CGRect(x: 900, y: 0, width: 400, height: 300), screens: screens) == 1)
        #expect(screenIndex(for: CGRect(x: 700, y: 0, width: 400, height: 300), screens: screens) == 0)
    }

    @Test func offscreenIsNil() {
        #expect(screenIndex(for: CGRect(x: -500, y: -500, width: 100, height: 100), screens: screens) == nil)
    }
}

struct FullScreenTests {
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    @Test func fullScreenAppMatches() {
        #expect(isFullScreen(window: CGRect(x: 0, y: 39, width: 1800, height: 1130), screen: screen, contentTop: 39))
    }

    @Test func maximizedWindowDoesNot() {
        #expect(!isFullScreen(window: CGRect(x: 0, y: 73, width: 1800, height: 1001), screen: screen, contentTop: 39))
        #expect(!isFullScreen(window: CGRect(x: 0, y: 39, width: 1800, height: 1036), screen: screen, contentTop: 39))
    }

    @Test func otherScreenDoesNot() {
        #expect(!isFullScreen(window: CGRect(x: 1800, y: 0, width: 1920, height: 1080), screen: screen, contentTop: 39))
    }
}

struct CloseActionTests {
    @Test func lastWindowQuits() {
        #expect(closeAction(windowCountForApp: 1, bundleID: "com.apple.Notes") == .quitApp)
    }

    @Test func otherWindowsRemain() {
        #expect(closeAction(windowCountForApp: 3, bundleID: "com.apple.Notes") == .closeWindow)
    }

    @Test func finderNeverQuits() {
        #expect(closeAction(windowCountForApp: 1, bundleID: "com.apple.finder") == .closeWindow)
    }
}

struct FrameClearingBarTests {
    // Menu bar 37pt, bar 34pt, visible area ends at 982.
    @Test func maximizedWindowShrinks() {
        let w = CGRect(x: 0, y: 37, width: 1512, height: 945)
        #expect(frameClearingBar(window: w, barBottom: 71, visibleBottom: 982) == CGRect(x: 0, y: 71, width: 1512, height: 911))
    }

    @Test func windowBelowBarUntouched() {
        #expect(frameClearingBar(window: CGRect(x: 0, y: 71, width: 800, height: 600), barBottom: 71, visibleBottom: 982) == nil)
        #expect(frameClearingBar(window: CGRect(x: 0, y: 200, width: 800, height: 600), barBottom: 71, visibleBottom: 982) == nil)
    }

    @Test func windowThatFitsSlidesDown() {
        let w = CGRect(x: 10, y: 40, width: 300, height: 400)
        #expect(frameClearingBar(window: w, barBottom: 71, visibleBottom: 982) == CGRect(x: 10, y: 71, width: 300, height: 400))
    }

    @Test func tallWindowKeepsBottomEdge() {
        let w = CGRect(x: 10, y: 50, width: 300, height: 920) // bottom at 970
        #expect(frameClearingBar(window: w, barBottom: 71, visibleBottom: 982) == CGRect(x: 10, y: 71, width: 300, height: 899))
    }

    @Test func neverReachesUnderTheDock() {
        let w = CGRect(x: 0, y: 39, width: 1800, height: 1100) // bottom at 1139, past the Dock
        #expect(frameClearingBar(window: w, barBottom: 73, visibleBottom: 1075) == CGRect(x: 0, y: 73, width: 1800, height: 1002))
    }
}

struct AppOrderTests {
    let a = "com.example.a", b = "com.example.b", c = "com.example.c", d = "com.example.d"

    @Test func openAppsKeepTheirNewOrderInTheirSlots() {
        // b is closed and keeps its slot; a and c swapped places.
        #expect(mergedAppOrder(saved: [a, b, c], current: [c, a]) == [c, b, a])
    }

    @Test func newAppsGoLast() {
        #expect(mergedAppOrder(saved: [a, c], current: [a, d, c]) == [a, d, c])
        #expect(mergedAppOrder(saved: [], current: [a, c]) == [a, c])
    }

    @Test func stableWhenNothingMoves() {
        let saved = [a, b, c]
        #expect(mergedAppOrder(saved: saved, current: [a, c]) == saved)
    }

    @Test func rankFollowsAppThenDiscovery() {
        #expect(initialRank(appIndex: 0, knownApps: 3, sequence: 7) < initialRank(appIndex: 1, knownApps: 3, sequence: 2))
        #expect(initialRank(appIndex: nil, knownApps: 3, sequence: 1) > initialRank(appIndex: 2, knownApps: 3, sequence: 99))
    }
}
