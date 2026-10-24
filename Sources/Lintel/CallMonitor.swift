import AppKit
import CoreAudio
import LintelCore

/// Apps capturing the microphone, from CoreAudio's process list (macOS 14.2+, no permission).
@MainActor
final class CallMonitor {
    var onChange: (() -> Void)?
    private(set) var appsInCall: Set<pid_t> = []
    /// Title of each app's call window, read on refresh rather than on every render.
    private(set) var callTitles: [pid_t: String] = [:]

    /// Stops the 3 s re-check, e.g. while the screens sleep; CoreAudio changes still arrive.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            callTimer?.invalidate()
            callTimer = nil
            if !isPaused { refresh() }
        }
    }

    private var apps: () -> [pid_t: NSRunningApplication] = { [:] }
    private var watched: Set<AudioObjectID> = []
    /// Re-checks every 3 s during a call, so a missed CoreAudio change can't leave it stuck.
    private var callTimer: Timer?

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static var processList = address(kAudioHardwarePropertyProcessObjectList)
    private static var runningInput = address(kAudioProcessPropertyIsRunningInput)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func start(apps: @escaping () -> [pid_t: NSRunningApplication]) {
        self.apps = apps
        AudioObjectAddPropertyListenerBlock(Self.system, &Self.processList, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func callWindowTitle(pid: pid_t) -> String? {
        let windows = AXUIElementCreateApplication(pid).value(kAXWindowsAttribute) as? [AXUIElement] ?? []
        return LintelCore.callWindowTitle(windows.map { window in
            let v = window.values([kAXTitleAttribute, kAXSubroleAttribute])
            return WindowTitle(title: v[0] as? String ?? "", isStandard: v[1] as? String == kAXStandardWindowSubrole)
        })
    }

    private var lastWindowCheck = Date.distantPast

    func windowsChanged() {
        guard Date().timeIntervalSince(lastWindowCheck) > 0.5 else { return }
        lastWindowCheck = Date()
        refresh()
    }

    private func refresh() {
        let processes = Self.processes()
        for process in processes where !watched.contains(process) {
            watched.insert(process)
            var address = Self.runningInput
            AudioObjectAddPropertyListenerBlock(process, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        watched.formIntersection(processes)

        let running = apps()
        let bundles = running.compactMap { $0.value.bundleIdentifier }
        var inCall = Set<pid_t>()
        for process in processes where Self.uint(process, kAudioProcessPropertyIsRunningInput) == 1 {
            guard let bundle = Self.string(process, kAudioProcessPropertyBundleID),
                  let owner = appOwning(audioProcess: bundle, among: bundles),
                  let pid = running.first(where: { $0.value.bundleIdentifier == owner })?.key
            else { continue }
            inCall.insert(pid)
        }
        if inCall.isEmpty || isPaused {
            callTimer?.invalidate()
            callTimer = nil
        } else if callTimer == nil {
            callTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        var titles: [pid_t: String] = [:]
        for pid in inCall { titles[pid] = callWindowTitle(pid: pid) }
        guard inCall != appsInCall || titles != callTitles else { return }
        appsInCall = inCall
        callTitles = titles
        onChange?()
    }

    private static func processes() -> [AudioObjectID] {
        var address = processList
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
