import SwiftUI

// Wraps a `TerminalSession`'s persistent `FinTerminalView`. `make{UI,NS}View` never
// constructs a new terminal view — it hands back the same live instance the
// session already owns, so switching away from and back to a session reparents
// the existing view (full scrollback, cursor, connection state intact) instead
// of recreating and re-rendering it.

#if os(macOS)

struct TerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let theme: AppTheme

    func makeNSView(context: Context) -> FinTerminalView {
        applyTheme(to: session.terminalView)
        return session.terminalView
    }

    func updateNSView(_ nsView: FinTerminalView, context: Context) {
        applyTheme(to: nsView)
    }

    private func applyTheme(to view: FinTerminalView) {
        let foreground = theme.foregroundPlatformColor
        let background = theme.backgroundPlatformColor
        view.nativeForegroundColor = foreground
        view.nativeBackgroundColor = background
        view.layer?.backgroundColor = background.cgColor
    }
}

#else

struct TerminalViewRepresentable: UIViewRepresentable {
    let session: TerminalSession
    let theme: AppTheme

    func makeUIView(context: Context) -> FinTerminalView {
        applyTheme(to: session.terminalView)
        return session.terminalView
    }

    func updateUIView(_ uiView: FinTerminalView, context: Context) {
        applyTheme(to: uiView)
    }

    private func applyTheme(to view: FinTerminalView) {
        let foreground = theme.foregroundPlatformColor
        let background = theme.backgroundPlatformColor
        view.nativeForegroundColor = foreground
        view.nativeBackgroundColor = background
        view.layer.backgroundColor = background.cgColor
    }
}

#endif
