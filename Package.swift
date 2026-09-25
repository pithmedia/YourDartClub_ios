// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "YourDartClubCore", platforms: [.macOS(.v13), .iOS(.v17)], products: [.library(name: "DartCore", targets: ["DartCore"])], targets: [.target(name: "DartCore", path: "YourDartClub/Core", linkerSettings: [.linkedLibrary("sqlite3")]), .testTarget(name: "DartCoreTests", dependencies: ["DartCore"], path: "YourDartClub/Tests")])
