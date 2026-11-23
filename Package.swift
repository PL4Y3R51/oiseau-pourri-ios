// swift-tools-version:6.0
// OiseauCore: everything of the app that is plain Swift — the API client, the
// session, the map's data and rules. No Apple-only framework, so it builds and
// tests on Windows and Linux too (`swift test`), where there is no Xcode.
// The SwiftUI app (App/, project.yml) depends on it.
import PackageDescription

let package = Package(
    name: "OiseauCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OiseauCore", targets: ["OiseauCore"])],
    targets: [
        .target(name: "OiseauCore", path: "Sources/OiseauCore"),
        .testTarget(
            name: "OiseauCoreTests",
            dependencies: ["OiseauCore"],
            path: "Tests/OiseauCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
