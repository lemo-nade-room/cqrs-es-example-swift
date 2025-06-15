// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "swift-otel-x-ray",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "OTLPXRay",
            targets: ["OTLPXRay"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "0.12.0"),
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "OTLPXRay",
            dependencies: [
                .product(name: "OTLPGRPC", package: "swift-otel"),
                .product(name: "AWSSDKHTTPAuth", package: "aws-sdk-swift"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OTLPXRayTests",
            dependencies: [
                .target(name: "OTLPXRay"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6],
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("NonescapableTypes"),
    ]
}