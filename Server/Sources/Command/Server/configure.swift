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
    app.logger.debug("[DEBUG] ========== configure() START ==========")
    app.logger.debug("[DEBUG] 🚀 Starting configure function")
    app.logger.debug("[DEBUG] Environment: \(app.environment)")
    app.logger.debug("[DEBUG] 📝 Environment variables:")
    app.logger.debug("[DEBUG] Lambda-specific:")
    app.logger.debug(
        "[DEBUG]   AWS_LAMBDA_FUNCTION_NAME: \(Environment.get("AWS_LAMBDA_FUNCTION_NAME") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   AWS_LAMBDA_FUNCTION_VERSION: \(Environment.get("AWS_LAMBDA_FUNCTION_VERSION") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   AWS_LAMBDA_FUNCTION_MEMORY_SIZE: \(Environment.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   AWS_LAMBDA_LOG_GROUP_NAME: \(Environment.get("AWS_LAMBDA_LOG_GROUP_NAME") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   AWS_LAMBDA_LOG_STREAM_NAME: \(Environment.get("AWS_LAMBDA_LOG_STREAM_NAME") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   AWS_EXECUTION_ENV: \(Environment.get("AWS_EXECUTION_ENV") ?? "not set")")
    app.logger.debug("[DEBUG] AWS Region:")
    app.logger.debug("[DEBUG]   AWS_REGION: \(Environment.get("AWS_REGION") ?? "not set")")
    app.logger.debug(
        "[DEBUG]   AWS_DEFAULT_REGION: \(Environment.get("AWS_DEFAULT_REGION") ?? "not set")")
    app.logger.debug("[DEBUG] X-Ray/Tracing:")
    app.logger.debug(
        "[DEBUG]   _X_AMZN_TRACE_ID: \(Environment.get("_X_AMZN_TRACE_ID") ?? "not set")")
    app.logger.debug(
        "[DEBUG]   AWS_XRAY_CONTEXT_MISSING: \(Environment.get("AWS_XRAY_CONTEXT_MISSING") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   AWS_XRAY_DAEMON_ADDRESS: \(Environment.get("AWS_XRAY_DAEMON_ADDRESS") ?? "not set")"
    )
    app.logger.debug("[DEBUG] OpenTelemetry:")
    app.logger.debug(
        "[DEBUG]   OTEL_EXPORTER_OTLP_ENDPOINT: \(Environment.get("OTEL_EXPORTER_OTLP_ENDPOINT") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   OTEL_PROPAGATORS: \(Environment.get("OTEL_PROPAGATORS") ?? "not set")")
    app.logger.debug(
        "[DEBUG]   OTEL_METRICS_EXPORTER: \(Environment.get("OTEL_METRICS_EXPORTER") ?? "not set")")
    app.logger.debug(
        "[DEBUG]   OTEL_AWS_APPLICATION_SIGNALS_ENABLED: \(Environment.get("OTEL_AWS_APPLICATION_SIGNALS_ENABLED") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   OTEL_AWS_APPLICATION_SIGNALS_EXPORTER_ENDPOINT: \(Environment.get("OTEL_AWS_APPLICATION_SIGNALS_EXPORTER_ENDPOINT") ?? "not set")"
    )
    app.logger.debug(
        "[DEBUG]   OTEL_RESOURCE_ATTRIBUTES: \(Environment.get("OTEL_RESOURCE_ATTRIBUTES") ?? "not set")"
    )
    app.logger.debug("[DEBUG] AWS Credentials:")
    app.logger.debug(
        "[DEBUG]   AWS_ACCESS_KEY_ID: \(Environment.get("AWS_ACCESS_KEY_ID") != nil ? "✅ present" : "❌ not set")"
    )
    app.logger.debug(
        "[DEBUG]   AWS_SECRET_ACCESS_KEY: \(Environment.get("AWS_SECRET_ACCESS_KEY") != nil ? "✅ present" : "❌ not set")"
    )
    app.logger.debug(
        "[DEBUG]   AWS_SESSION_TOKEN: \(Environment.get("AWS_SESSION_TOKEN") != nil ? "✅ present" : "❌ not set")"
    )
    app.logger.debug("[DEBUG] Application:")
    app.logger.debug("[DEBUG]   SERVER: \(Environment.get("SERVER") ?? "not set")")
    app.logger.debug("[DEBUG]   LOG_LEVEL: \(Environment.get("LOG_LEVEL") ?? "not set")")
    app.logger.debug("[DEBUG] Lambda Web Adapter:")
    app.logger.debug("[DEBUG]   AWS_LWA_PORT: \(Environment.get("AWS_LWA_PORT") ?? "not set")")
    app.logger.debug(
        "[DEBUG]   AWS_LWA_ENABLE_COMPRESSION: \(Environment.get("AWS_LWA_ENABLE_COMPRESSION") ?? "not set")"
    )

    // ================================
    // OpenTelemetry Configuration
    // ================================
    app.logger.debug("[DEBUG] 🔭 Starting OpenTelemetry configuration")
    let otlpEndpoint = Environment.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    let serviceName = Environment.get("AWS_LAMBDA_FUNCTION_NAME") ?? "command-server"
    app.logger.debug("[DEBUG] OpenTelemetry parameters:")
    app.logger.debug("[DEBUG]   Service name: \(serviceName)")
    app.logger.debug("[DEBUG]   OTLP endpoint: \(otlpEndpoint ?? "default")")

    app.logger.debug("[DEBUG] Calling OpenTelemetryConfiguration.configureOpenTelemetry...")
    try await OpenTelemetryConfiguration.configureOpenTelemetry(
        serviceName: serviceName,
        otlpEndpoint: otlpEndpoint,
        eventLoopGroup: app.eventLoopGroup
    )
    app.logger.debug("[DEBUG] ✅ OpenTelemetry configuration completed")

    app.logger.debug("[DEBUG] Getting tracer for instrumentation...")
    let tracer = OpenTelemetryConfiguration.getTracer(instrumentationName: "CommandServer")
    app.logger.debug("[DEBUG] ✅ Tracer obtained: \(type(of: tracer))")

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
    app.logger.debug("[DEBUG] 📋 Registering OpenAPI handlers")
    try service.registerHandlers(on: transport, serverURL: serverURL)
    app.logger.debug("[DEBUG] ✅ OpenAPI handlers registered successfully")
    app.logger.debug("[DEBUG] ========== configure() END ==========")
    app.logger.debug("[DEBUG] 🎉 Configure function completed successfully!")
}
