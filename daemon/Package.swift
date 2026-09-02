// swift-tools-version:5.10
// fin-agentd — headless daemon extraction of Fin's agent runtime.
//
// FinAgentCore is the single source of truth for the shared agent logic: the app's
// XcodeGen project (../project.yml) includes daemon/Sources/FinAgentCore as an
// additional sources path of the `fin` target, so the same files compile into both the
// app and this package. Dependency versions deliberately mirror project.yml.
import PackageDescription

let package = Package(
    name: "fin-agentd",
    platforms: [
        // Citadel's withPTY is @available(macOS 15.0, *) — same floor as the app.
        // String form because `.v15` needs PackageDescription 6.0 and this manifest
        // stays at 5.10 for the app-matching Swift 5 language mode.
        .macOS("15.0"),
    ],
    products: [
        .library(name: "FinAgentCore", targets: ["FinAgentCore"]),
        .executable(name: "fin-agentd", targets: ["FinAgentDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.12.1"),
        // Same-identity override of Citadel's swift-nio-ssh dependency, pinned to the
        // fork project.yml uses.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", from: "0.3.4"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "FinAgentCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "FinAgentDaemon",
            dependencies: ["FinAgentCore"],
            path: "Sources/fin-agentd"
        ),
        .testTarget(
            name: "FinAgentCoreTests",
            dependencies: ["FinAgentCore"]
        ),
        .testTarget(
            name: "FinAgentDaemonTests",
            dependencies: ["FinAgentDaemon", "FinAgentCore"]
        ),
    ]
)
