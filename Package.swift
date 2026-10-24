// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "devicehubctl",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "devicehubctl", path: "Sources/devicehubctl"),
  ]
)
