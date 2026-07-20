// swift-tools-version:5.9
import PackageDescription

// A separate package so the SwiftUI app never breaks the library's Linux build. CI builds
// this on macOS, which is the only place AppKit and SwiftUI exist.
let package = Package(
	name: "MacExample",
	platforms: [.macOS(.v12)],
	dependencies: [.package(path: "../..")],
	targets: [
		.executableTarget(name: "MacExample", dependencies: [.product(name: "CoolBeans", package: "coolbeans-swift")])
	]
)
