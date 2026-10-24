import AppKit
import LintelCore

/// Claude Code sessions, from the files scripts/agent-hook.sh writes.
@MainActor
final class AgentMonitor {
    var onChange: (() -> Void)?

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lintel/agents", isDirectory: true)

    private var records: [String: AgentRecord] = [:]
    private var apps: () -> [pid_t: NSRunningApplication] = { [:] }
    private var folderSource: DispatchSourceFileSystemObject?
    /// Records are listed, read and deleted through this descriptor, never by path: another
    /// program could swap the folder for a link to elsewhere.
    private var folderFD: Int32 = -1
    private var exitSources: [pid_t: DispatchSourceProcess] = [:]
    private var activatedAt: [pid_t: Date] = [:]
    private var expiryTimer: Timer?

    func start(apps: @escaping () -> [pid_t: NSRunningApplication]) {
        self.apps = apps
        openFolder()
        // "Done" clears once the user comes back to the app.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activatedAt[pid] = Date()
                self.onChange?()
            }
        }
        reload()
    }

    func summary(for pid: pid_t) -> AgentSummary? {
        let now = Date()
        let states = records.values
            .filter { appPID(of: $0) == pid && isAgentStateVisible($0, now: now, appActivatedAt: activatedAt[pid]) }
            .map(\.state)
        return agentSummary(states)
    }

    func sessions(for pid: pid_t) -> [AgentRecord] {
        let now = Date()
        return records.values
            .filter { appPID(of: $0) == pid && isAgentStateVisible($0, now: now, appActivatedAt: activatedAt[pid]) }
            .sorted(by: agentListOrder)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        folderFD = open(Self.folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let fd = open(Self.folder.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.folderSource else { return }
                // The folder was deleted or moved: watch a fresh one at the expected path.
                if !source.data.isDisjoint(with: [.delete, .rename]) { self.reopenFolder() }
                self.reload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderSource = source
    }

    private func reopenFolder() {
        folderSource?.cancel()
        folderSource = nil
        if folderFD >= 0 { close(folderFD) }
        folderFD = -1
        openFolder()
    }

    /// Lists the folder through a duplicate of `folderFD`, which closedir closes.
    private func recordNames() -> [String] {
        let fd = dup(folderFD)
        guard fd >= 0 else { return [] }
        guard let dir = fdopendir(fd) else {
            close(fd)
            return []
        }
        defer { closedir(dir) }
        // The duplicate shares folderFD's offset, left at the end by the previous listing.
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            var name = entry.pointee.d_name
            names.append(withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
        return names
    }

    private func appPID(of record: AgentRecord) -> pid_t? {
        let running = apps()
        if let bundleID = record.appBundleID,
           let match = running.first(where: { $0.value.bundleIdentifier == bundleID }) {
            return match.key
        }
        return record.chain.first { running[$0.pid] != nil }?.pid
    }

    private func reload() {
        let names = recordNames()
        var fresh: [String: AgentRecord] = [:]
        for name in names where !name.hasPrefix(".") {
            guard let text = readRecord(name), let record = parseAgentRecord(text) else { continue }
            // Claude was killed without a SessionEnd hook: drop the stale file.
            if let pid = record.claudePID, !isAlive(pid) {
                removeRecord(name)
                continue
            }
            fresh[name] = record
            if let pid = record.claudePID { watchExit(of: pid) }
        }
        records = fresh
        // A session that ends while its app is frontmost needs no "Done" label.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           fresh.values.contains(where: { $0.state == .done && appPID(of: $0) == front }) {
            activatedAt[front] = Date()
        }
        let watched = Set(fresh.values.compactMap(\.claudePID))
        for pid in exitSources.keys where !watched.contains(pid) {
            exitSources.removeValue(forKey: pid)?.cancel()
        }
        scheduleExpiry()
        onChange?()
    }

    private func watchExit(of pid: pid_t) {
        guard exitSources[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.exitSources.removeValue(forKey: pid)?.cancel()
                for (name, record) in self.records where record.claudePID == pid {
                    self.removeRecord(name)
                }
            }
        }
        source.resume()
        exitSources[pid] = source
    }

    /// A regular file of at most 64 KB: a link or a huge file is not a record.
    private func readRecord(_ name: String) -> String? {
        let fd = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 65_536,
              let data = try? file.readToEnd()
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// unlinkat without AT_REMOVEDIR removes files only.
    private func removeRecord(_ name: String) {
        unlinkat(folderFD, name, 0)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        let now = Date()
        guard let next = records.values
            .filter({ $0.state == .running })
            .map({ $0.updated.addingTimeInterval(600) })
            .filter({ $0 > now })
            .min()
        else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange?()
                self?.scheduleExpiry()
            }
        }
    }
}
