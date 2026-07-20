// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "CoolBeans",
	platforms: [.macOS(.v11), .iOS(.v14)],
	products: [
		.library(name: "CoolBeans", targets: ["CoolBeans"]),
		.executable(name: "coolbeans-example", targets: ["coolbeans-example"]),
	],
	dependencies: [
		// Apple platforms use the system CryptoKit and link nothing extra. swift-crypto is
		// Apple's own source-compatible implementation, pulled in only where CryptoKit does
		// not exist — which is what lets the whole decision table be tested on Linux CI
		// rather than only on a Mac.
		.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
	],
	targets: [
		.target(
			name: "CoolBeans",
			dependencies: [
				.product(
					name: "Crypto",
					package: "swift-crypto",
					condition: .when(platforms: [.linux, .windows, .android])
				),
			]
		),
		.executableTarget(name: "coolbeans-example", dependencies: ["CoolBeans"]),
		.testTarget(name: "CoolBeansTests", dependencies: ["CoolBeans"]),
	]
)
