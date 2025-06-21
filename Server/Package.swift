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

        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "1.0.0"),
    ],
    targets: [
        // MARK: Command
        .executableTarget(
            name: "CommandServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
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
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
    ]
}
