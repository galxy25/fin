// The tvOS terminal renderer: SwiftTerm's UIKit TerminalView doesn't exist on
// tvOS, so this draws the headless engine's cell buffer directly with CoreText.
// The vendored engine compiles into this same module, so buffer internals are
// reachable without any SwiftTerm source changes.
import UIKit
import SwiftUI
import CoreText

final class TerminalCanvasUIView: UIView {
    var session: TVTerminalSession? {
        didSet {
            guard session !== oldValue else { return }
            hookSession()
            recomputeGridAndResize()
            scheduleRender()
        }
    }

    var themeBackground: UIColor = .black { didSet { backgroundColor = themeBackground; scheduleRender() } }
    var themeForeground: UIColor = UIColor(red: 0, green: 1, blue: 0, alpha: 1) { didSet { scheduleRender() } }

    private let font: UIFont
    private let boldFont: UIFont
    private let cellSize: CGSize
    private var renderScheduled = false

    override init(frame: CGRect) {
        let base = UIFont(name: "Menlo", size: 23) ?? UIFont.monospacedSystemFont(ofSize: 23, weight: .regular)
        let bold = UIFont(name: "Menlo-Bold", size: 23) ?? UIFont.monospacedSystemFont(ofSize: 23, weight: .bold)
        self.font = base
        self.boldFont = bold
        let advance = ("W" as NSString).size(withAttributes: [.font: base])
        self.cellSize = CGSize(width: ceil(advance.width), height: ceil(base.lineHeight))
        super.init(frame: frame)
        backgroundColor = themeBackground
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Focus

    // The canvas is the terminal screen's sole focusable element, so a Bluetooth
    // keyboard's arrow keys (which the focus engine also sees) have nowhere to move
    // focus — the only observable effect is the CSI sequence GCKeyboard sends.
    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        layer.borderWidth = isFocused ? 2 : 0
        layer.borderColor = themeForeground.withAlphaComponent(0.6).cgColor
    }

    // MARK: Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeGridAndResize()
    }

    private var insetBounds: CGRect { bounds.insetBy(dx: 12, dy: 10) }

    private func recomputeGridAndResize() {
        guard let session, insetBounds.width > cellSize.width, insetBounds.height > cellSize.height else { return }
        let cols = Int(insetBounds.width / cellSize.width)
        let rows = Int(insetBounds.height / cellSize.height)
        session.resize(cols: cols, rows: rows)
    }

    // MARK: Rendering

    private func hookSession() {
        session?.onScreenUpdate = { [weak self] in
            self?.scheduleRender()
        }
    }

    /// Feeds arrive in bursts; coalesce to ~30 Hz rather than redrawing per chunk.
    func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
            self?.renderScheduled = false
            self?.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let session else { return }
        let terminal = session.terminal
        let buffer = terminal.buffer
        let origin = insetBounds.origin
        let rows = terminal.rows
        let cols = terminal.cols

        themeBackground.setFill()
        context.fill(bounds)

        for row in 0..<rows {
            let lineIndex = buffer.yDisp + row
            guard lineIndex < buffer.lines.count else { break }
            let line = buffer.lines[lineIndex]
            let rowTop = origin.y + CGFloat(row) * cellSize.height

            // Background cells first, then one text pass for the row.
            let attributed = NSMutableAttributedString()
            for col in 0..<cols {
                let charData = line[col]
                let attribute = charData.attribute
                var fg = color(for: attribute.fg, isForeground: true)
                var bg = color(for: attribute.bg, isForeground: false)
                if attribute.style.contains(.inverse) { swap(&fg, &bg) }
                if attribute.style.contains(.dim) { fg = fg.withAlphaComponent(0.6) }

                if !isDefaultBackground(attribute) || attribute.style.contains(.inverse) {
                    bg.setFill()
                    context.fill(CGRect(
                        x: origin.x + CGFloat(col) * cellSize.width,
                        y: rowTop,
                        width: cellSize.width,
                        height: cellSize.height
                    ))
                }

                var character = charData.getCharacter()
                if character == "\u{0}" { character = " " }
                if attribute.style.contains(.invisible) { character = " " }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: attribute.style.contains(.bold) ? boldFont : font,
                    .foregroundColor: fg,
                ]
                if attribute.style.contains(.underline) {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.underlineColor] = fg
                }
                attributed.append(NSAttributedString(string: String(character), attributes: attrs))
            }

            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: origin.x, y: rowTop + font.ascender)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }

        // Cursor block (semi-transparent so the glyph under it stays legible).
        let cursorCol = buffer.x
        let cursorRow = buffer.y
        if cursorRow >= 0, cursorRow < rows, cursorCol >= 0, cursorCol < cols {
            themeForeground.withAlphaComponent(0.45).setFill()
            context.fill(CGRect(
                x: origin.x + CGFloat(cursorCol) * cellSize.width,
                y: origin.y + CGFloat(cursorRow) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            ))
        }
    }

    // MARK: Colors

    private func isDefaultBackground(_ attribute: Attribute) -> Bool {
        if case .defaultColor = attribute.bg { return true }
        return false
    }

    private func color(for attributeColor: Attribute.Color, isForeground: Bool) -> UIColor {
        switch attributeColor {
        case .defaultColor:
            return isForeground ? themeForeground : themeBackground
        case .defaultInvertedColor:
            return isForeground ? themeBackground : themeForeground
        case .ansi256(let code):
            return Self.ansiPalette[Int(code)]
        case .trueColor(let red, let green, let blue):
            return UIColor(
                red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1
            )
        }
    }

    /// Standard xterm 256-color palette: 16 named, 216 color cube, 24 grays.
    private static let ansiPalette: [UIColor] = {
        var palette: [UIColor] = []
        let base: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
            (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        for (r, g, b) in base {
            palette.append(UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1))
        }
        let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
        for r in steps { for g in steps { for b in steps {
            palette.append(UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1))
        } } }
        for i in 0..<24 {
            let level = CGFloat(8 + i * 10) / 255
            palette.append(UIColor(red: level, green: level, blue: level, alpha: 1))
        }
        return palette
    }()
}

struct TerminalCanvas: UIViewRepresentable {
    let session: TVTerminalSession
    let backgroundHex: String
    let foregroundHex: String

    func makeUIView(context: Context) -> TerminalCanvasUIView {
        let view = TerminalCanvasUIView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateUIView(_ view: TerminalCanvasUIView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: TerminalCanvasUIView) {
        view.themeBackground = UIColor(hexString: backgroundHex) ?? .black
        view.themeForeground = UIColor(hexString: foregroundHex) ?? UIColor(red: 0, green: 1, blue: 0, alpha: 1)
        view.session = session
    }
}

extension UIColor {
    /// Parses "#RRGGBB" (the AppTheme storage format).
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
