Vendored subset of SwiftTerm (https://github.com/migueldeicaza/SwiftTerm), tag v1.20.0,
MIT License (see LICENSE) — Copyright (c) Miguel de Icaza and SwiftTerm contributors.

Only the platform-independent headless terminal-emulation engine is vendored here,
compiled directly into the fin-tv (tvOS) target. tvOS is excluded from the upstream
package's UIKit view layer, and using the upstream package for the engine alone would
collide with the iOS/macOS targets' pinned SwiftTerm package in the same project.
Upstream files excluded: Apple/, iOS/, Mac/, Documentation.docc, LocalProcess.swift,
HeadlessTerminal.swift, Pty.swift, TerminalViewSearch.swift, File.swift.
Local changes are marked with '// fin-tv:' comments.
