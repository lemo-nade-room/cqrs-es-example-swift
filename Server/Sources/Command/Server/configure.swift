import OpenAPIRuntime
import OpenAPIVapor
import OpenTelemetryApi
import OpenTelemetrySdk
import Tracing
import Vapor

func configure(_ app: Application) async throws {
    // ================================
    // OpenTelemetry Configuration
    // ================================
    let otlpEndpoint = Environment.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    try await OpenTelemetryConfiguration.configureOpenTelemetry(
        serviceName: "command-server",
        otlpEndpoint: otlpEndpoint,
        app: app
    )

    let tracer = OpenTelemetryConfiguration.getTracer(instrumentationName: "CommandServer")

    // ================================
    // HTTP Server Configuration
    // ================================
    if app.environment == .development {
        app.http.server.configuration.port = 3001
    }

    // ================================
    // Lambda Web Adapter
    // ================================
    app.get { _ in "It works!" }

    // ================================
    // Middleware Configuration
    // ================================
    app.middleware.use(OpenTelemetryTracingMiddleware(tracer: tracer))
    app.middleware.use(VaporRequestMiddleware())

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
    try service.registerHandlers(on: transport, serverURL: serverURL)
}
