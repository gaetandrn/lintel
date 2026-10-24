import AppKit
import CoreText

/// Tinted glass pill, drawn by hand to center the text's cap height rather than its line box.
class GlassPillView: NSView {
    enum Leading: Equatable { case none, dot, phone }

    static let height: CGFloat = 18

    private let blur = NSVisualEffectView()
    private let content = GlassContentView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Self.height / 2
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        addSubview(blur)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(text: String, tint: NSColor, leading: Leading, centered: Bool = false) {
        guard text != content.text || tint != content.tint || leading != content.leading || centered != content.centered else { return }
        content.text = text
        content.tint = tint
        content.leading = leading
        content.centered = centered
        content.needsDisplay = true
    }

    override var fittingSize: NSSize {
        NSSize(width: content.preferredWidth, height: Self.height)
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        content.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.height / 2, cornerHeight: Self.height / 2, transform: nil)
    }

    // Clicks go to the tab.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class GlassContentView: NSView {
    var text = ""
    var tint = NSColor.systemBlue
    var leading = GlassPillView.Leading.none
    var centered = false

    private static let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let attributes: [NSAttributedString.Key: Any] = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1
        return [.font: font, .foregroundColor: NSColor.white, .kern: 0.1, .shadow: shadow]
    }()

    // Margins are measured to the ink (dot edge, last glyph). A round mark against the
    // pill's round end reads farther from the edge, hence the smaller leading margin.
    private static let leadingMargin: CGFloat = 6.5
    private static let trailingMargin: CGFloat = 7.5
    private static let markGap: CGFloat = 5
    private static let dotSize: CGFloat = 6.5
    private static let phoneSize: CGFloat = 9
    private static let counterMargin: CGFloat = 6

    override var isFlipped: Bool { true }

    private var ink: (minX: CGFloat, maxX: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return bounds.isEmpty ? (0, 0) : (bounds.minX, bounds.maxX)
    }

    private var markWidth: CGFloat {
        switch leading {
        case .none: 0
        case .dot: Self.dotSize
        case .phone: Self.phoneSize
        }
    }

    var preferredWidth: CGFloat {
        let ink = ink
        if centered { return ceil(max(GlassPillView.height, ink.maxX - ink.minX + 2 * Self.counterMargin)) }
        let mark = leading == .none ? 0 : markWidth + Self.markGap
        return ceil(Self.leadingMargin + mark + ink.maxX + Self.trailingMargin)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = r.height / 2
        let pill = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        pill.addClip()

        NSGradient(starting: tint.withAlphaComponent(0.62), ending: tint.withAlphaComponent(0.5))?.draw(in: r, angle: 90)
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSRect(x: r.minX, y: r.minY, width: r.width, height: 0.5).fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let hairline = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: radius - 0.25, yRadius: radius - 0.25)
        hairline.lineWidth = 0.5
        hairline.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let midY = r.height / 2
        let ink = ink
        var x = centered ? (r.width - (ink.maxX - ink.minX)) / 2 - ink.minX : Self.leadingMargin
        switch leading {
        case .none:
            break
        case .dot:
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = NSColor.white.withAlphaComponent(0.7)
            glow.shadowBlurRadius = 4
            glow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize)).fill()
            NSGraphicsContext.restoreGraphicsState()
            x += Self.dotSize + Self.markGap
        case .phone:
            if let symbol = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8.5, weight: .bold).applying(.init(paletteColors: [.white]))) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: x + (Self.phoneSize - size.width) / 2, y: midY - size.height / 2, width: size.width, height: size.height))
            }
            x += Self.phoneSize + Self.markGap
        }

        // NSString draws from the top of the line box, at baseline - ascender.
        let font = Self.font
        let baseline = midY + font.capHeight / 2
        (text as NSString).draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: Self.attributes)
    }
}
