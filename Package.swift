// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "kakaocli",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kakaocli", targets: ["KakaoCLI"]),
        .library(name: "KakaoCore", targets: ["KakaoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "swift-6.2.3-RELEASE"),
    ],
    targets: [
        .executableTarget(
            name: "KakaoCLI",
            dependencies: [
                "KakaoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "KakaoCore",
            dependencies: ["CSQLCipher", "CKakaoRecovery"]
        ),
        .target(name: "CKakaoRecovery", publicHeadersPath: "include"),
        .systemLibrary(
            name: "CSQLCipher",
            pkgConfig: "sqlcipher",
            providers: [.brew(["sqlcipher"])]
        ),
        .testTarget(
            name: "KakaoCoreTests",
            dependencies: ["KakaoCore", "CSQLCipher", .product(name: "Testing", package: "swift-testing")]
        ),
    ],
    cLanguageStandard: .c11
)
