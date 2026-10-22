// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoongdoongTranscription",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DoongdoongTranscription", targets: ["DoongdoongTranscription"]),
        .executable(name: "doongdoong-transcribe", targets: ["TranscribeCLI"])
    ],
    targets: [
        .target(name: "DoongdoongTranscription"),
        .executableTarget(name: "TranscribeCLI", dependencies: ["DoongdoongTranscription"]),
        .testTarget(name: "DoongdoongTranscriptionTests", dependencies: ["DoongdoongTranscription"])
    ],
    swiftLanguageModes: [.v6]
)
