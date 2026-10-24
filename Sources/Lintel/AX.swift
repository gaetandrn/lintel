import ApplicationServices
import AppKit

/// AXUIElement wrapper usable as a dictionary key (AX elements compare with CFEqual).
struct ElementKey: Hashable {
    let element: AXUIElement

    static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

extension AXUIElement {
    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }

    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// Reads several attributes in a single IPC round trip; missing ones come back nil.
    func values(_ attributes: [String]) -> [CFTypeRef?] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, attributes as CFArray, [], &result) == .success,
              let array = result as? [CFTypeRef], array.count == attributes.count
        else { return Array(repeating: nil, count: attributes.count) }
        return array.map { isAXError($0) ? nil : $0 }
    }

    func bool(_ attribute: String) -> Bool { (value(attribute) as? Bool) ?? false }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    var frame: CGRect? {
        let v = values([kAXPositionAttribute, kAXSizeAttribute])
        guard let position = cgPoint(v[0]), let size = cgSize(v[1]) else { return nil }
        return CGRect(origin: position, size: size)
    }

    func setFrame(_ frame: CGRect) {
        // Size, position, size: macOS clamps a move that leaves a too-tall window
        // off-screen, so shrink first and reapply the size once in place.
        var origin = frame.origin
        var size = frame.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        set(kAXSizeAttribute, s)
        set(kAXPositionAttribute, p)
        set(kAXSizeAttribute, s)
    }
}

private func isAXError(_ value: CFTypeRef) -> Bool {
    CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError
}

func cgPoint(_ value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}

func cgSize(_ value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}
