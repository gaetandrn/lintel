import Foundation

/// The app owning an audio helper, whose bundle id extends the app's; longest match wins.
public func appOwning(audioProcess bundleID: String, among apps: [String]) -> String? {
    apps.filter { bundleID == $0 || bundleID.hasPrefix($0 + ".") }.max { $0.count < $1.count }
}

public struct WindowTitle: Equatable {
    public let title: String
    /// AXStandardWindow subrole: the windows shown in the bar.
    public let isStandard: Bool
    /// When the bar first saw the window; nil for a window it does not track.
    public let firstSeen: Date?

    public init(title: String, isStandard: Bool, firstSeen: Date? = nil) {
        self.title = title
        self.isStandard = isStandard
        self.firstSeen = firstSeen
    }
}

/// How far the call window opening and the microphone starting can be from each other.
let callWindowDelay: TimeInterval = 10

/// The window holding the call, for an app that is using the microphone:
/// 1. Microsoft Teams' compact view names it ("Meeting compact view | <title>"), in any language;
/// 2. else the window the app opened as the microphone started, whatever it is called — the
///    only way to recognise a meeting named "Synchro NG";
/// 3. else a window titled like a call: a call in a browser tab opens no window at all.
public func callWindowTitle(_ windows: [WindowTitle], micStartedAt: Date? = nil) -> String? {
    for window in windows where !window.isStandard {
        if let range = window.title.range(of: " | ") {
            let title = String(window.title[range.upperBound...])
            if windows.contains(where: { $0.isStandard && $0.title == title }) { return title }
        }
    }
    if let micStartedAt, let title = windowOpenedWithTheCall(windows, micStartedAt: micStartedAt) {
        return title
    }
    // Never fall back to the only window: Teams closes the call window just before it
    // releases the microphone, and its main window would be taken for the call.
    return windows.first { $0.isStandard && isCallTitle($0.title) }?.title
}

/// The newest window the app opened around the time the microphone started. Windows the bar
/// discovered together (it just started, or so did the app) say nothing about which one holds
/// the call, so the whole set opening at once is no answer at all.
private func windowOpenedWithTheCall(_ windows: [WindowTitle], micStartedAt: Date) -> String? {
    let standard = windows.filter(\.isStandard)
    let opened = standard.filter { window in
        window.firstSeen.map { abs($0.timeIntervalSince(micStartedAt)) < callWindowDelay } ?? false
    }
    guard opened.count < standard.count else { return nil }
    return opened.max { ($0.firstSeen ?? .distantPast) < ($1.firstSeen ?? .distantPast) }?.title
}

/// English and French words that mark a call window, matched as whole words in any case.
let callTitleWords: Set<String> = ["meeting", "meet", "call", "réunion", "appel"]

func isCallTitle(_ title: String) -> Bool {
    title.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { callTitleWords.contains(String($0)) }
}
