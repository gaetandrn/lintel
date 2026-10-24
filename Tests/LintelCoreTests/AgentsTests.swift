import Foundation
import Testing
@testable import LintelCore

struct AgentSummaryTests {
    @Test func nothingToShow() {
        #expect(agentSummary([]) == nil)
    }

    @Test func oneAndSeveralRunning() {
        #expect(agentSummary([.running]) == AgentSummary(state: .running, count: 1))
        #expect(agentSummary([.running, .running]) == AgentSummary(state: .running, count: 2))
    }

    @Test func waitingComesFirst() {
        #expect(agentSummary([.running, .waiting, .done]) == AgentSummary(state: .waiting, count: 1))
        #expect(agentSummary([.waiting, .running, .waiting]) == AgentSummary(state: .waiting, count: 2))
    }

    @Test func doneLast() {
        #expect(agentSummary([.done]) == AgentSummary(state: .done, count: 1))
        #expect(agentSummary([.done, .running, .done]) == AgentSummary(state: .running, count: 1))
        #expect(agentSummary([.done, .done]) == AgentSummary(state: .done, count: 2))
    }
}

struct AgentRecordTests {
    let sample = """
    waiting 1792745000 com.example.terminal 1792744880
    cwd /Users/alex/Projects/website
    51230 /bin/sh
    51200 /Users/alex/.local/bin/claude
    40100 -zsh
    39955 /Applications/Terminal.app/Contents/MacOS/Terminal
    1 /sbin/launchd
    """

    @Test func parsesStateTimeAndChain() throws {
        let record = try #require(parseAgentRecord(sample))
        #expect(record.state == .waiting)
        #expect(record.updated == Date(timeIntervalSince1970: 1_792_745_000))
        #expect(record.appBundleID == "com.example.terminal")
        #expect(record.since == Date(timeIntervalSince1970: 1_792_744_880))
        #expect(record.cwd == "/Users/alex/Projects/website")
        #expect(record.chain.count == 5)
        #expect(record.chain[3] == .init(pid: 39955, command: "/Applications/Terminal.app/Contents/MacOS/Terminal"))
    }

    @Test func findsTheClaudeProcess() throws {
        #expect(try #require(parseAgentRecord(sample)).claudePID == 51200)
    }

    @Test func rejectsGarbage() {
        #expect(parseAgentRecord("") == nil)
        #expect(parseAgentRecord("thinking 12 -") == nil)
        #expect(parseAgentRecord("running soon -") == nil)
        #expect(parseAgentRecord("running 12") == nil)
    }

    @Test func olderFilesWithoutStartTimeOrFolder() throws {
        let record = try #require(parseAgentRecord("done 12 -\n40 claude"))
        #expect(record.appBundleID == nil)
        #expect(record.since == record.updated)
        #expect(record.cwd == nil)
        #expect(record.claudePID == 40)
    }

    @Test func emptyFolderLineIsNoFolder() throws {
        let record = try #require(parseAgentRecord("running 12 -\ncwd \n40 claude"))
        #expect(record.cwd == nil)
        #expect(record.chain == [.init(pid: 40, command: "claude")])
    }

    @Test func folderWithSpaces() throws {
        let record = try #require(parseAgentRecord("running 12 -\ncwd /Users/alex/My Projects/web site\n40 claude"))
        #expect(record.cwd == "/Users/alex/My Projects/web site")
    }

    @Test func noClaudeAncestor() throws {
        #expect(try #require(parseAgentRecord("running 12 -\n41 /bin/sh\n40 -zsh\n1 /sbin/launchd")).claudePID == nil)
    }

    @Test func nearestClaudeAncestorWins() throws {
        let record = try #require(parseAgentRecord("running 12 -\n42 /bin/sh\n41 /opt/claude/bin/claude\n40 /usr/local/bin/claude"))
        #expect(record.claudePID == 41)
    }
}

struct AgentVisibilityTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func record(_ state: AgentState) -> AgentRecord { AgentRecord(state: state, updated: t0, since: t0, appBundleID: nil, cwd: nil, chain: []) }

    @Test func runningExpiresAfterTenMinutes() {
        #expect(isAgentStateVisible(record(.running), now: t0.addingTimeInterval(599), appActivatedAt: nil))
        #expect(!isAgentStateVisible(record(.running), now: t0.addingTimeInterval(601), appActivatedAt: nil))
    }

    @Test func doneClearsWhenYouComeBack() {
        #expect(isAgentStateVisible(record(.done), now: t0, appActivatedAt: nil))
        #expect(isAgentStateVisible(record(.done), now: t0, appActivatedAt: t0.addingTimeInterval(-5)))
        #expect(!isAgentStateVisible(record(.done), now: t0, appActivatedAt: t0.addingTimeInterval(5)))
    }

    @Test func waitingStays() {
        #expect(isAgentStateVisible(record(.waiting), now: t0.addingTimeInterval(3600), appActivatedAt: t0.addingTimeInterval(10)))
    }
}

struct AgentListTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func minutesInState() {
        #expect(agentMinutesInState(since: t0, now: t0.addingTimeInterval(30)) == 0)
        #expect(agentMinutesInState(since: t0, now: t0.addingTimeInterval(4 * 60 + 10)) == 4)
        #expect(agentMinutesInState(since: t0, now: t0.addingTimeInterval(65 * 60)) == 65)
    }

    @Test func urgentFirstThenOldest() {
        func r(_ s: AgentState, _ since: TimeInterval) -> AgentRecord {
            AgentRecord(state: s, updated: t0, since: t0.addingTimeInterval(since), appBundleID: nil, cwd: nil, chain: [])
        }
        let sorted = [r(.done, 0), r(.running, 50), r(.waiting, 90), r(.running, 10)].sorted(by: agentListOrder)
        #expect(sorted.map(\.state) == [.waiting, .running, .running, .done])
        #expect(sorted[1].since < sorted[2].since)
    }
}
