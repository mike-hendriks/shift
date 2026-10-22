// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shift",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Shift", targets: ["Shift"]),
        .executable(name: "shift-cli", targets: ["ShiftCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", exact: "1.6.0"),
    ],
    targets: [
        .target(name: "ShiftCore", dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")]),
        .executableTarget(
            name: "Shift",
            dependencies: ["ShiftCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into Shift.app/Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "ShiftCLI", dependencies: ["ShiftCore"]),
    ],
    swiftLanguageModes: [.v5]
)
