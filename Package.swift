// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LetterboxdKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "LetterboxdKit", targets: ["LetterboxdKit"])],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")
    ],
    targets: [
        .target(name: "LetterboxdKit", dependencies: ["SwiftSoup"], path: "Sources/LetterboxdKit"),
        .testTarget(name: "LetterboxdKitTests", dependencies: ["LetterboxdKit"], path: "Tests/LetterboxdKitTests",
                    resources: [.copy("Fixtures")])
    ]
)
