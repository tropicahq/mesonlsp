// swift-tools-version: 5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Swift-MesonLSP",
  platforms: [.macOS("10.15.4")],
  products: [
    .library(name: "MesonAnalyze", targets: ["MesonAnalyze"]),
    .library(name: "MesonAST", targets: ["MesonAST"]),
    .library(name: "LanguageServer", targets: ["LanguageServer"]),
    .library(name: "IOUtils", targets: ["IOUtils"]), .library(name: "Timing", targets: ["Timing"]),
    .library(name: "MesonDocs", targets: ["MesonDocs"]),
    .library(name: "TestingFramework", targets: ["TestingFramework"]),
    .library(name: "CMem", targets: ["CMem"]), .library(name: "Wrap", targets: ["Wrap"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.7.1"),
    .package(url: "https://github.com/JCWasmx86/tree-sitter-meson", from: "1.0.7"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.2"),
    .package(url: "https://github.com/apple/sourcekit-lsp", branch: "main"),
    .package(url: "https://github.com/httpswift/swifter.git", .upToNextMajor(from: "1.5.0")),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.2"),
    .package(url: "https://github.com/vapor/console-kit.git", from: "4.6.0"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.3"),
    .package(url: "https://github.com/PerfectlySoft/Perfect-INIParser.git", from: "4.0.0"),
  ],
  targets: [
    .target(
      name: "MesonAnalyze",
      dependencies: [
        "Timing", "SwiftTreeSitter", "MesonAST", "IOUtils",
        .product(name: "Logging", package: "swift-log"),
      ]
    ), .systemLibrary(name: "CMem"), .target(name: "Timing", dependencies: []),
    .target(name: "IOUtils", dependencies: []),
    .target(
      name: "Wrap",
      dependencies: [.product(name: "INIParser", package: "Perfect-INIParser")]
    ), .target(name: "MesonDocs", dependencies: []),
    .target(
      name: "TestingFramework",
      dependencies: ["MesonAnalyze", .product(name: "Logging", package: "swift-log")]
    ), .target(name: "MesonAST", dependencies: ["IOUtils", "SwiftTreeSitter", "Timing"]),
    .target(
      name: "LanguageServer",
      dependencies: [
        "MesonAnalyze", "Timing", "MesonDocs", "CMem", "IOUtils",
        .product(
          name: "Swifter",
          package: "swifter",
          condition: .when(platforms: [.linux, .macOS])
        ), .product(name: "LSPBindings", package: "sourcekit-lsp"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Atomics", package: "swift-atomics"),
      ]
    ),
    .executableTarget(
      name: "Swift-MesonLSP",
      dependencies: [
        "SwiftTreeSitter", "MesonAnalyze", "MesonAST", "LanguageServer", "Timing",
        "TestingFramework", "Wrap", .product(name: "ConsoleKit", package: "console-kit"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "TreeSitterMeson", package: "tree-sitter-meson"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "LSPBindings", package: "sourcekit-lsp"),
      ]
    ), .testTarget(name: "Swift-MesonLSPTests", dependencies: ["Swift-MesonLSP"]),
  ]
)
