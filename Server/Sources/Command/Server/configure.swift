import OpenAPIRuntime
import OpenAPIVapor
import OpenTelemetryApi
import OpenTelemetrySdk
import Tracing
import Vapor

func configure(_ app: Application) async throws {
    // ================================
    // Debug Logging
    // ================================
    app.logger.debug("🚀 Starting configure()")

    // Lambda環境の検出
    let isLambda = Environment.get("AWS_EXECUTION_ENV")?.starts(with: "AWS_Lambda") == true
    let functionName = Environment.get("AWS_LAMBDA_FUNCTION_NAME") ?? "unknown"
    let region = Environment.get("AWS_REGION") ?? "not set"

    app.logger.debug(
        "🌐 Environment: \(app.environment) | Lambda: \(isLambda ? "✅" : "❌") | Function: \(functionName)"
    )
    app.logger.debug(
        "📍 Region: \(region) | Memory: \(Environment.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE") ?? "N/A")MB"
    )

    // OpenTelemetry設定の要約
    if let otlpEndpoint = Environment.get("OTEL_EXPORTER_OTLP_ENDPOINT") {
        app.logger.debug("📡 OTLP Endpoint: \(otlpEndpoint)")
    }
    if let resourceAttrs = Environment.get("OTEL_RESOURCE_ATTRIBUTES") {
        app.logger.debug("🏷️ Resource: \(resourceAttrs)")
    }

    // 認証状態の確認
    let hasCredentials =
        Environment.get("AWS_ACCESS_KEY_ID") != nil
        && Environment.get("AWS_SECRET_ACCESS_KEY") != nil
    app.logger.debug("🔐 AWS Credentials: \(hasCredentials ? "✅ Ready" : "❌ Missing")")

    // ================================
    // OpenTelemetry Configuration
    // ================================
    app.logger.debug("🔧 Configuring OpenTelemetry...")
    let otlpEndpoint = Environment.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    let serviceName = "CommandServer"  // 固定のサービス名を使用

    try await OpenTelemetryConfiguration.configureOpenTelemetry(
        serviceName: serviceName,
        otlpEndpoint: otlpEndpoint,
        eventLoopGroup: app.eventLoopGroup
    )

    let tracer = OpenTelemetryConfiguration.getTracer(instrumentationName: "CommandServer")
    app.logger.debug("✅ OpenTelemetry ready with service: \(serviceName)")

    // ================================
    // HTTP Server Configuration
    // ================================
    if app.environment == .development {
        app.http.server.configuration.port = 3001
    }

    // ================================
    // Lambda Web Adapter
    // ================================
    app.get { req in
        return "It works!"
    }

    // ================================
    // Middleware Configuration
    // ================================
    app.middleware.use(OpenTelemetryTracingMiddleware(tracer: tracer))
    app.middleware.use(VaporRequestMiddleware())
    app.logger.debug("🧩 Middleware stack ready")

    // ================================
    // OpenAPI Vapor Transport
    // ================================
    let transport = VaporTransport(routesBuilder: app)
    let service = Service(logger: app.logger)
    let serverURL: URL =
        switch Environment.get("SERVER") {
        case "Staging": try Servers.Server2.url()
        default: try Servers.Server1.url()
        }
    app.logger.info("📋 Service registered: \(serverURL)")
    try service.registerHandlers(on: transport, serverURL: serverURL)
    app.logger.debug("🎉 Configuration complete!")
}
