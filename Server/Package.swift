// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Server",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),

        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),

        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "0.12.0"),
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.0.0"),
    ],
    targets: [
        // MARK: OTLPXRay
        .target(
            name: "OTLPXRay",
            dependencies: [
                .product(name: "OTLPGRPC", package: "swift-otel"),
                .product(name: "AWSSDKHTTPAuth", package: "aws-sdk-swift"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/OTLPXRay",
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "OTLPXRayTests",
            dependencies: [
                .target(name: "OTLPXRay"),
            ],
            path: "Tests/OTLPXRayTests",
            swiftSettings: swiftSettings,
        ),
        
        // MARK: Command
        .executableTarget(
            name: "CommandServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .target(name: "OTLPXRay"),
            ],
            path: "Sources/Command/Server",
            swiftSettings: swiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ],
        ),
        .testTarget(
            name: "CommandServerTests",
            dependencies: [
                .target(name: "CommandServer"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            path: "Tests/Command/ServerTests",
            swiftSettings: swiftSettings,
        ),

        // MARK: Query
        .executableTarget(
            name: "QueryServer",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/Query/Server",
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "QueryServerTests",
            dependencies: [
                .target(name: "QueryServer"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            path: "Tests/Query/ServerTests",
            swiftSettings: swiftSettings,
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
