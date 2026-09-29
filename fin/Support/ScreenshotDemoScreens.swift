import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Synthetic content for the App Store captures of the features that need a live
/// remote end to show anything: Remote Desktop, Remote Browser, and a terminal
/// reached through the Fin relay (SSH tunnelled over HTTPS).
///
/// The live versions are a relay + a resident daemon streaming a real screen, which
/// is exactly what a capture must not photograph — a real desktop carries the
/// owner's windows, tabs and names. So a capture (`FIN_SCREENSHOT_MODE=1`) gets
/// these instead, injected at the same seam the live bytes/frames would enter
/// (`RemoteBrowserSession.open`, `TerminalSession.connectSiteRelay`): everything
/// downstream — the frame view, the tab menu, the terminal engine, the control
/// strip — is the shipping code path rendering shipping data.
///
/// Every name is invented (Northwind, example.com); no third-party brand appears.
enum ScreenshotDemoScreens {
    // MARK: - Relay terminal

    /// What "Build Box" prints when a capture opens it over the relay. ANSI, fed to the
    /// real terminal engine, so colour, wrapping and the cursor are the app's own.
    static func relayTerminalScript() -> [UInt8] {
        let esc = "\u{1B}["
        func c(_ code: String, _ text: String) -> String { "\(esc)\(code)m\(text)\(esc)0m" }
        let prompt = c("1;32", "ci@build") + c("0", ":") + c("1;34", "~/fin") + c("0", " % ")
        var s = "\(esc)2J\(esc)H"
        s += prompt + "hostname; uptime\r\n"
        s += "build-box.example.com\r\n"
        s += " 10:38:12 up 41 days,  3:07,  1 user,  load average: 3.42, 2.91, 2.18\r\n\r\n"
        s += prompt + "tmux ls\r\n"
        s += "ci: 2 windows (created Mon Sep 28 22:00:04) (attached)\r\n"
        s += "deploy: 1 windows (created Tue Sep 29 09:58:31)\r\n\r\n"
        s += prompt + "tail -n 12 /srv/staging/deploy.log\r\n"
        let lines: [(String, String)] = [
            ("32", "[1/6] fetching release 2026.09.29-3 … ok"),
            ("32", "[2/6] migrating database (14 statements) … ok"),
            ("32", "[3/6] building assets … ok (18.4s)"),
            ("32", "[4/6] syncing assets to 2 nodes … ok"),
            ("32", "[5/6] restarting app servers … ok (2 nodes)"),
            ("32", "[6/6] health check … 200 OK in 0.31s"),
        ]
        for (code, text) in lines { s += c(code, text) + "\r\n" }
        s += c("1;32", "deploy complete") + " — 2026-09-29 10:41:02\r\n\r\n"
        s += prompt + "df -h /srv | tail -1\r\n"
        s += "/dev/nvme0n1p2  468G  212G  256G  46% /srv\r\n\r\n"
        s += prompt
        return Array(s.utf8)
    }

    // MARK: - Remote Desktop / Remote Browser frames

    struct Screen {
        var image: CGImage
        var viewport: CGSize
        var url: String?
        var title: String?
        var tabs: [RemoteBrowserProtocol.Tab]
        var selectedTab: String?
        var displays: [RemoteBrowserProtocol.Display]
        var selectedDisplay: String?
    }

    static func screen(mode: RemoteBrowserSession.Mode) -> Screen? {
        switch mode {
        case .desktop:
            let size = CGSize(width: 1600, height: 1000)
            guard let image = render(size: size, draw: drawDesktop) else { return nil }
            return Screen(
                image: image, viewport: size, url: nil, title: "Studio iMac", tabs: [], selectedTab: nil,
                displays: [
                    RemoteBrowserProtocol.Display(id: "1", label: "Studio Display"),
                    RemoteBrowserProtocol.Display(id: "2", label: "Built-in Retina Display"),
                ],
                selectedDisplay: "1"
            )
        case .browser:
            // A real frame streamed from a live browser (cropped from a Mac capture) when
            // the run supplies one; the drawn page otherwise.
            let size = CGSize(width: 1280, height: 860)
            var image = liveFrame(named: "browser")
            var viewport = image.map { CGSize(width: $0.width, height: $0.height) } ?? size
            if image == nil { image = render(size: size, draw: drawBrowserPage); viewport = size }
            guard let image else { return nil }
            let tabs = [
                RemoteBrowserProtocol.Tab(id: "t1", title: "Northwind Deploys", url: "https://deploys.example.com/releases"),
                RemoteBrowserProtocol.Tab(id: "t2", title: "Northwind Status", url: "https://status.example.com"),
            ]
            let live = liveFrame(named: "browser") != nil
            return Screen(
                image: image, viewport: viewport,
                url: live ? "https://africanintellect.club/" : "https://deploys.example.com/releases",
                title: live ? "AfricanIntellect.club" : "Northwind Deploys",
                tabs: live ? [RemoteBrowserProtocol.Tab(id: "t1", title: "AfricanIntellect.club", url: "https://africanintellect.club/")] : tabs,
                selectedTab: "t1", displays: [], selectedDisplay: nil
            )
        }
    }

    /// `<FIN_SCREENSHOT_FRAMES_DIR>/<name>.jpg`, when the capture run points at one.
    private static func liveFrame(named name: String) -> CGImage? {
        guard let dir = ProcessInfo.processInfo.environment["FIN_SCREENSHOT_FRAMES_DIR"], !dir.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(name).jpg")),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Drawing

    private static func render(size: CGSize, draw: (Canvas) -> Void) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Flip to a top-left origin so layout reads like a page.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(Canvas(ctx: ctx, size: size))
        return ctx.makeImage()
    }

    struct Canvas {
        let ctx: CGContext
        let size: CGSize

        static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
            )
        }

        func fill(_ rect: CGRect, _ hex: UInt32, radius: CGFloat = 0, alpha: CGFloat = 1) {
            ctx.setFillColor(Self.color(hex, alpha))
            if radius > 0 {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            } else {
                ctx.fill(rect)
            }
        }

        func stroke(_ rect: CGRect, _ hex: UInt32, radius: CGFloat = 0, width: CGFloat = 1) {
            ctx.setStrokeColor(Self.color(hex))
            ctx.setLineWidth(width)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        }

        func gradient(_ rect: CGRect, top: UInt32, bottom: UInt32) {
            let g = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Self.color(top), Self.color(bottom)] as CFArray,
                locations: [0, 1]
            )!
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
            ctx.restoreGState()
        }

        func text(
            _ string: String, at point: CGPoint, size: CGFloat, hex: UInt32 = 0x1D1D1F,
            mono: Bool = false, bold: Bool = false, alpha: CGFloat = 1
        ) {
            let name = mono ? (bold ? "Menlo-Bold" : "Menlo") : (bold ? "HelveticaNeue-Bold" : "HelveticaNeue")
            let font = CTFontCreateWithName(name as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): Self.color(hex, alpha),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            ctx.saveGState()
            // Text is drawn in the flipped space; counter-flip around the baseline.
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: point.x, y: point.y + size)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    private static func drawDesktop(_ c: Canvas) {
        let w = c.size.width, h = c.size.height
        c.gradient(CGRect(x: 0, y: 0, width: w, height: h), top: 0x1E3A5F, bottom: 0x6C4A8E)
        // Menu bar.
        c.fill(CGRect(x: 0, y: 0, width: w, height: 30), 0x000000, alpha: 0.35)
        c.text("Fin", at: CGPoint(x: 18, y: 7), size: 15, hex: 0xFFFFFF, bold: true)
        for (i, item) in ["File", "Edit", "View", "Window", "Help"].enumerated() {
            c.text(item, at: CGPoint(x: 70 + CGFloat(i) * 62, y: 8), size: 14, hex: 0xFFFFFF, alpha: 0.9)
        }
        c.text("Tue 29 Sep  10:41", at: CGPoint(x: w - 170, y: 8), size: 14, hex: 0xFFFFFF, alpha: 0.9)

        // Terminal window: a build in flight.
        let term = CGRect(x: 90, y: 90, width: 860, height: 560)
        c.fill(term.offsetBy(dx: 0, dy: 10), 0x000000, radius: 12, alpha: 0.25)
        c.fill(term, 0x14161A, radius: 12)
        c.fill(CGRect(x: term.minX, y: term.minY, width: term.width, height: 34), 0x2A2D33, radius: 12)
        for (i, dot) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            c.fill(CGRect(x: term.minX + 14 + CGFloat(i) * 22, y: term.minY + 11, width: 12, height: 12), UInt32(dot), radius: 6)
        }
        c.text("fin — xcodebuild archive", at: CGPoint(x: term.midX - 90, y: term.minY + 9), size: 13, hex: 0xC8CCD4)
        let rows: [(String, UInt32)] = [
            ("fin % xcodebuild archive -scheme fin -destination 'platform=macOS,arch=arm64'", 0xE6E9EF),
            ("Resolve Package Graph … done", 0x8A93A3),
            ("CompileSwift normal arm64 AgentRuntime.swift", 0x8A93A3),
            ("CompileSwift normal arm64 TerminalSession.swift", 0x8A93A3),
            ("CompileSwift normal arm64 RemoteBrowserSession.swift", 0x8A93A3),
            ("Ld build/fin.app/Contents/MacOS/fin normal", 0x8A93A3),
            ("CodeSign build/fin.app", 0x8A93A3),
            ("Archive Succeeded", 0x5AD17A),
            ("", 0),
            ("fin % ./scripts/testflight-macos.sh", 0xE6E9EF),
            ("Uploading to App Store Connect … 71%", 0xF2C14E),
        ]
        for (i, row) in rows.enumerated() where !row.0.isEmpty {
            c.text(row.0, at: CGPoint(x: term.minX + 22, y: term.minY + 54 + CGFloat(i) * 26), size: 15, hex: row.1, mono: true)
        }
        c.fill(CGRect(x: term.minX + 22, y: term.minY + 54 + CGFloat(rows.count) * 26 - 2, width: 10, height: 18), 0xE6E9EF, alpha: 0.85)

        // A notes-style window: the runbook the agent is following.
        let doc = CGRect(x: 690, y: 210, width: 780, height: 610)
        c.fill(doc.offsetBy(dx: 0, dy: 12), 0x000000, radius: 12, alpha: 0.28)
        c.fill(doc, 0xFAFAF7, radius: 12)
        c.fill(CGRect(x: doc.minX, y: doc.minY, width: doc.width, height: 34), 0xE9E9E4, radius: 12)
        for (i, dot) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            c.fill(CGRect(x: doc.minX + 14 + CGFloat(i) * 22, y: doc.minY + 11, width: 12, height: 12), UInt32(dot), radius: 6)
        }
        c.text("Deploy Runbook.md", at: CGPoint(x: doc.midX - 60, y: doc.minY + 9), size: 13, hex: 0x555555)
        c.text("Release checklist", at: CGPoint(x: doc.minX + 36, y: doc.minY + 62), size: 30, bold: true)
        let steps: [(String, Bool)] = [
            ("Run the full test suite on the build box", true),
            ("Archive all four platforms", true),
            ("Upload builds to App Store Connect", false),
            ("Confirm processing, then notify the team", false),
            ("Tag the release and write the changelog", false),
        ]
        for (i, step) in steps.enumerated() {
            let y = doc.minY + 130 + CGFloat(i) * 46
            c.fill(CGRect(x: doc.minX + 36, y: y, width: 22, height: 22), step.1 ? 0x2E9E5B : 0xFFFFFF, radius: 5)
            if !step.1 { c.stroke(CGRect(x: doc.minX + 36, y: y, width: 22, height: 22), 0xB7B7B0, radius: 5, width: 1.5) }
            if step.1 { c.text("✓", at: CGPoint(x: doc.minX + 40, y: y + 1), size: 18, hex: 0xFFFFFF, bold: true) }
            c.text(step.0, at: CGPoint(x: doc.minX + 74, y: y + 1), size: 20, hex: step.1 ? 0x8A8A85 : 0x1D1D1F)
        }

        // Dock.
        let dock = CGRect(x: w / 2 - 300, y: h - 96, width: 600, height: 76)
        c.fill(dock, 0xFFFFFF, radius: 22, alpha: 0.22)
        let tints: [UInt32] = [0x3B82F6, 0x22C55E, 0xF59E0B, 0xEF4444, 0x8B5CF6, 0x06B6D4, 0xEC4899, 0x64748B]
        for (i, tint) in tints.enumerated() {
            c.fill(CGRect(x: dock.minX + 22 + CGFloat(i) * 70, y: dock.minY + 10, width: 56, height: 56), tint, radius: 13)
        }
    }

    private static func drawBrowserPage(_ c: Canvas) {
        let w = c.size.width, h = c.size.height
        c.fill(CGRect(x: 0, y: 0, width: w, height: h), 0xF4F6F9)
        c.fill(CGRect(x: 0, y: 0, width: w, height: 68), 0x0F172A)
        c.fill(CGRect(x: 32, y: 20, width: 28, height: 28), 0x38BDF8, radius: 8)
        c.text("Northwind Deploys", at: CGPoint(x: 74, y: 21), size: 24, hex: 0xFFFFFF, bold: true)
        for (i, item) in ["Releases", "Environments", "Alerts", "Settings"].enumerated() {
            c.text(item, at: CGPoint(x: 420 + CGFloat(i) * 130, y: 24), size: 18, hex: i == 0 ? 0xFFFFFF : 0x94A3B8, bold: i == 0)
        }

        c.text("Releases", at: CGPoint(x: 48, y: 104), size: 36, bold: true)
        c.text("Production and staging, most recent first", at: CGPoint(x: 50, y: 152), size: 18, hex: 0x64748B)

        // Summary cards.
        let cards: [(String, String, UInt32)] = [
            ("Production", "2026.09.29-3", 0x16A34A), ("Staging", "2026.09.29-4", 0x16A34A), ("Error rate", "0.02%", 0x0EA5E9),
        ]
        for (i, card) in cards.enumerated() {
            let rect = CGRect(x: 48 + CGFloat(i) * 396, y: 200, width: 372, height: 130)
            c.fill(rect, 0xFFFFFF, radius: 14)
            c.stroke(rect, 0xE2E8F0, radius: 14)
            c.text(card.0.uppercased(), at: CGPoint(x: rect.minX + 24, y: rect.minY + 22), size: 14, hex: 0x64748B, bold: true)
            c.text(card.1, at: CGPoint(x: rect.minX + 24, y: rect.minY + 52), size: 34, bold: true)
            c.fill(CGRect(x: rect.minX + 24, y: rect.minY + 100, width: 10, height: 10), card.2, radius: 5)
            c.text(i == 2 ? "within budget" : "healthy", at: CGPoint(x: rect.minX + 42, y: rect.minY + 96), size: 15, hex: 0x475569)
        }

        // Release table.
        let table = CGRect(x: 48, y: 370, width: w - 96, height: 440)
        c.fill(table, 0xFFFFFF, radius: 14)
        c.stroke(table, 0xE2E8F0, radius: 14)
        for (i, head) in ["Release", "Environment", "Deployed", "Status"].enumerated() {
            c.text(head.uppercased(), at: CGPoint(x: table.minX + 28 + CGFloat(i) * 290, y: table.minY + 24), size: 13, hex: 0x64748B, bold: true)
        }
        let rows: [(String, String, String, String, UInt32)] = [
            ("2026.09.29-4", "Staging", "10:41 today", "Healthy", 0x16A34A),
            ("2026.09.29-3", "Production", "09:12 today", "Healthy", 0x16A34A),
            ("2026.09.28-2", "Production", "yesterday", "Superseded", 0x94A3B8),
            ("2026.09.28-1", "Staging", "yesterday", "Superseded", 0x94A3B8),
            ("2026.09.26-5", "Production", "Sat", "Rolled back", 0xF59E0B),
            ("2026.09.26-4", "Staging", "Sat", "Superseded", 0x94A3B8),
        ]
        for (i, row) in rows.enumerated() {
            let y = table.minY + 70 + CGFloat(i) * 56
            c.fill(CGRect(x: table.minX + 1, y: y - 10, width: table.width - 2, height: 1), 0xEEF2F6)
            c.text(row.0, at: CGPoint(x: table.minX + 28, y: y + 6), size: 19, mono: true)
            c.text(row.1, at: CGPoint(x: table.minX + 318, y: y + 6), size: 19)
            c.text(row.2, at: CGPoint(x: table.minX + 608, y: y + 6), size: 19, hex: 0x475569)
            c.fill(CGRect(x: table.minX + 898, y: y + 10, width: 12, height: 12), row.4, radius: 6)
            c.text(row.3, at: CGPoint(x: table.minX + 920, y: y + 6), size: 19, hex: 0x1E293B)
        }
    }
}
