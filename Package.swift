// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoongdoongTranscription",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoongdoongTranscription", targets: ["DoongdoongTranscription"]),
        .executable(name: "doongdoong-transcribe", targets: ["TranscribeCLI"])
    ],
    targets: [
        .target(name: "DoongdoongTranscription", resources: [.copy("Resources")]),
        .executableTarget(name: "TranscribeCLI", dependencies: ["DoongdoongTranscription"]),
        .testTarget(name: "DoongdoongTranscriptionTests", dependencies: ["DoongdoongTranscription"])
    ],
    swiftLanguageModes: [.v5]
)
