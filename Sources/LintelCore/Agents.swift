import Foundation

/// State of a Claude Code session, as written by scripts/agent-hook.sh.
public enum AgentState: String, Equatable {
    case running, waiting, done
}

/// The most urgent state among an app's sessions, and how many sessions are in it.
public struct AgentSummary: Equatable {
    public let state: AgentState
    public let count: Int
}

/// Only the most urgent state is shown (waiting, running, done), to keep the label short.
public func agentSummary(_ states: [AgentState]) -> AgentSummary? {
    for state in [AgentState.waiting, .running, .done] {
        let count = states.filter { $0 == state }.count
        if count > 0 { return AgentSummary(state: state, count: count) }
    }
    return nil
}

public struct AgentRecord: Equatable {
    public let state: AgentState
    public let updated: Date
    /// When the session entered its current state.
    public let since: Date
    /// Bundle id of the hosting app, from `__CFBundleIdentifier`.
    public let appBundleID: String?
    public let cwd: String?
    /// Ancestors of the hook process, nearest first.
    public let chain: [Ancestor]

    public struct Ancestor: Equatable {
        public let pid: Int32
        public let command: String
    }

    public var claudePID: Int32? {
        chain.first { ($0.command as NSString).lastPathComponent.lowercased().contains("claude") }?.pid
    }
}

/// Parses "<state> <unix time> <bundle id or -> [<state start time>]", an optional
/// "cwd <path>" line, then one "<pid> <command>" line per ancestor.
public func parseAgentRecord(_ text: String) -> AgentRecord? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard let header = lines.first else { return nil }
    let fields = header.split(separator: " ")
    guard (3...4).contains(fields.count), let state = AgentState(rawValue: String(fields[0])), let time = TimeInterval(fields[1]) else { return nil }
    let bundleID = fields[2] == "-" ? nil : String(fields[2])
    let since = fields.count == 4 ? TimeInterval(fields[3]) ?? time : time
    let cwd = lines.first { $0.hasPrefix("cwd ") }.map { String($0.dropFirst(4)) }.flatMap { $0.isEmpty ? nil : $0 }
    let chain = lines.dropFirst().filter { !$0.hasPrefix("cwd ") }.compactMap { line -> AgentRecord.Ancestor? in
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
        return AgentRecord.Ancestor(pid: pid, command: String(parts[1]))
    }
    return AgentRecord(
        state: state, updated: Date(timeIntervalSince1970: time), since: Date(timeIntervalSince1970: since),
        appBundleID: bundleID, cwd: cwd, chain: chain
    )
}

/// "Running" with no event for 10 minutes is treated as interrupted, since Esc fires no
/// Stop hook. "Done" hides once the user has come back to the app.
public func isAgentStateVisible(_ record: AgentRecord, now: Date, appActivatedAt: Date?) -> Bool {
    switch record.state {
    case .running: return now.timeIntervalSince(record.updated) < 600
    case .waiting: return true
    case .done: return appActivatedAt.map { $0 < record.updated } ?? true
    }
}

public func agentMinutesInState(since: Date, now: Date) -> Int {
    Int(now.timeIntervalSince(since) / 60)
}

/// Most urgent first, then the longest in its state.
public func agentListOrder(_ a: AgentRecord, _ b: AgentRecord) -> Bool {
    let rank: (AgentState) -> Int = { [.waiting: 0, .running: 1, .done: 2][$0]! }
    return rank(a.state) != rank(b.state) ? rank(a.state) < rank(b.state) : a.since < b.since
}
