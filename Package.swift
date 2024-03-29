// swift-tools-version:5.5

import PackageDescription

let package = Package(
	name: "ChimeGo",
	platforms: [.macOS(.v11)],
	products: [
		.library(name: "ChimeGo", targets: ["ChimeGo"]),
	],
	dependencies: [
		.package(url: "https://github.com/ChimeHQ/ChimeKit", from: "0.3.0"),
	],
	targets: [
		.target(name: "ChimeGo", dependencies: ["ChimeKit"]),
		.testTarget(name: "ChimeGoTests", dependencies: ["ChimeGo"]),
	]
)
