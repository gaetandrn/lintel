import Foundation
import LintelCore

/// User-facing strings, from Localizable.strings and Localizable.stringsdict in the app bundle.
enum L10n {
    static var openAtLogin: String { tr("menu.openAtLogin") }
    static var keepWindowsBelowBar: String { tr("menu.keepWindowsBelowBar") }
    static var textColor: String { tr("menu.textColor") }
    static var textColorAutomatic: String { tr("menu.textColor.automatic") }
    static var textColorLight: String { tr("menu.textColor.light") }
    static var textColorDark: String { tr("menu.textColor.dark") }
    static var quitLintel: String { tr("menu.quitLintel") }
    static func version(_ version: String) -> String { String.localizedStringWithFormat(tr("menu.version"), version) }
    static var titleBarZoom: String { tr("menu.titleBarZoom") }
    static var checkForUpdates: String { tr("menu.checkForUpdates") }

    static func updateAvailable(_ version: String) -> String { String.localizedStringWithFormat(tr("update.available"), version) }
    static func updateAvailableMessage(current: String) -> String { String.localizedStringWithFormat(tr("update.available.message"), current) }
    static var updateCopyCommand: String { tr("update.copyCommand") }
    static var updateLater: String { tr("update.later") }
    static var upToDate: String { tr("update.upToDate") }
    static var updateFailed: String { tr("update.failed") }
    static var ok: String { tr("update.ok") }

    static var closeWindow: String { tr("tab.closeWindow") }
    static func quitApp(_ name: String) -> String { String.localizedStringWithFormat(tr("tab.quitApp"), name) }
    static func pinApp(_ name: String) -> String { String.localizedStringWithFormat(tr("tab.pinApp"), name) }
    static func unpinApp(_ name: String) -> String { String.localizedStringWithFormat(tr("tab.unpinApp"), name) }
    static func tabToolTip(app: String, title: String) -> String { String.localizedStringWithFormat(tr("tab.toolTip"), app, title) }
    static var close: String { tr("tab.close") }
    static func overflow(_ count: Int) -> String { String.localizedStringWithFormat(tr("tab.overflow"), count) }

    static var inCall: String { tr("status.inCall") }

    static func agentState(_ state: AgentState, count: Int = 1) -> String {
        let key = switch state {
        case .running: "agent.running"
        case .waiting: "agent.waiting"
        case .done: "agent.done"
        }
        return String.localizedStringWithFormat(tr(key), count)
    }

    static func agentSummary(_ summary: AgentSummary) -> String { agentState(summary.state, count: summary.count) }

    static func duration(minutes: Int) -> String {
        if minutes < 1 { return tr("agent.duration.now") }
        if minutes < 60 { return String.localizedStringWithFormat(tr("agent.duration.minutes"), minutes) }
        return String.localizedStringWithFormat(tr("agent.duration.hours"), minutes / 60, minutes % 60)
    }

    static var untitledSession: String { tr("sessions.untitled") }

    // Bundle.main rather than SwiftPM's Bundle.module: the module bundle's path is baked in
    // at build time and is missing once the binary is copied into a hand-assembled .app.
    private static func tr(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}
