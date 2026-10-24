import Foundation

/// The app owning an audio helper, whose bundle id extends the app's; longest match wins.
public func appOwning(audioProcess bundleID: String, among apps: [String]) -> String? {
    apps.filter { bundleID == $0 || bundleID.hasPrefix($0 + ".") }.max { $0.count < $1.count }
}

public struct WindowTitle: Equatable {
    public let title: String
    /// AXStandardWindow subrole: the windows shown in the bar.
    public let isStandard: Bool

    public init(title: String, isStandard: Bool) {
        self.title = title
        self.isStandard = isStandard
    }
}

/// The call window named by Microsoft Teams' compact view ("Meeting compact view | <title>"),
/// in any language; otherwise the first standard window titled like a call.
public func callWindowTitle(_ windows: [WindowTitle]) -> String? {
    for window in windows where !window.isStandard {
        if let range = window.title.range(of: " | ") {
            let title = String(window.title[range.upperBound...])
            if windows.contains(where: { $0.isStandard && $0.title == title }) { return title }
        }
    }
    // Never fall back to the only window: Teams closes the call window just before it
    // releases the microphone, and its main window would be taken for the call.
    return windows.first { $0.isStandard && isCallTitle($0.title) }?.title
}

/// English and French words that mark a call window, matched as whole words in any case.
let callTitleWords: Set<String> = ["meeting", "meet", "call", "réunion", "appel"]

func isCallTitle(_ title: String) -> Bool {
    title.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { callTitleWords.contains(String($0)) }
}
