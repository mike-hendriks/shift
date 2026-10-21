// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shift",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Shift", targets: ["Shift"]),
        .executable(name: "shift-cli", targets: ["ShiftCLI"]),
    ],
    targets: [
        .target(name: "ShiftCore"),
        .executableTarget(name: "Shift", dependencies: ["ShiftCore"]),
        .executableTarget(name: "ShiftCLI", dependencies: ["ShiftCore"]),
    ],
    swiftLanguageModes: [.v5]
)
