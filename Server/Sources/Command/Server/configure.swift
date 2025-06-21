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
    app.logger.debug("[DEBUG] Starting configure function")
    app.logger.debug("[DEBUG] Environment: \(app.environment)")
    app.logger.debug("[DEBUG] Environment variables:")
    app.logger.debug("[DEBUG]   AWS_LAMBDA_FUNCTION_NAME: \(Environment.get("AWS_LAMBDA_FUNCTION_NAME") ?? "not set")")
    app.logger.debug("[DEBUG]   AWS_REGION: \(Environment.get("AWS_REGION") ?? "not set")")
    app.logger.debug("[DEBUG]   AWS_EXECUTION_ENV: \(Environment.get("AWS_EXECUTION_ENV") ?? "not set")")
    app.logger.debug("[DEBUG]   OTEL_EXPORTER_OTLP_ENDPOINT: \(Environment.get("OTEL_EXPORTER_OTLP_ENDPOINT") ?? "not set")")
    app.logger.debug("[DEBUG]   AWS_ACCESS_KEY_ID: \(Environment.get("AWS_ACCESS_KEY_ID") != nil ? "present" : "not set")")
    app.logger.debug("[DEBUG]   AWS_SECRET_ACCESS_KEY: \(Environment.get("AWS_SECRET_ACCESS_KEY") != nil ? "present" : "not set")")
    app.logger.debug("[DEBUG]   AWS_SESSION_TOKEN: \(Environment.get("AWS_SESSION_TOKEN") != nil ? "present" : "not set")")
    app.logger.debug("[DEBUG]   SERVER: \(Environment.get("SERVER") ?? "not set")")
    app.logger.debug("[DEBUG]   AWS_LWA_PORT: \(Environment.get("AWS_LWA_PORT") ?? "not set")")

    // ================================
    // OpenTelemetry Configuration
    // ================================
    let otlpEndpoint = Environment.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    app.logger.debug("[DEBUG] Configuring OpenTelemetry with endpoint: \(otlpEndpoint ?? "default")")
    
    try await OpenTelemetryConfiguration.configureOpenTelemetry(
        serviceName: Environment.get("AWS_LAMBDA_FUNCTION_NAME") ?? "command-server",
        otlpEndpoint: otlpEndpoint,
        eventLoopGroup: app.eventLoopGroup
    )
    app.logger.debug("[DEBUG] OpenTelemetry configuration completed")

    let tracer = OpenTelemetryConfiguration.getTracer(instrumentationName: "CommandServer")
    app.logger.debug("[DEBUG] Tracer obtained")

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
        req.logger.debug("[DEBUG] Root endpoint hit")
        return "It works!"
    }

    // ================================
    // Middleware Configuration
    // ================================
    app.logger.debug("[DEBUG] Adding OpenTelemetryTracingMiddleware")
    app.middleware.use(OpenTelemetryTracingMiddleware(tracer: tracer))
    app.logger.debug("[DEBUG] Adding VaporRequestMiddleware")
    app.middleware.use(VaporRequestMiddleware())
    app.logger.debug("[DEBUG] Middleware configuration completed")

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
    app.logger.info("Service registered on Server URL: \(serverURL)")
    app.logger.debug("[DEBUG] Registering OpenAPI handlers")
    try service.registerHandlers(on: transport, serverURL: serverURL)
    app.logger.debug("[DEBUG] Configure function completed successfully")
}
