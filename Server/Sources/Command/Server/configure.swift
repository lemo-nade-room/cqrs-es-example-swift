import ClientRuntime
import OTel
import OpenAPIRuntime
import OpenAPIVapor
import Tracing
import Vapor

func configure(_ app: Application) async throws {
    // ================================
    // OpenAPI Vapor Transport
    // ================================
    let transport = VaporTransport(routesBuilder: app)
    let service = Service()
    let serverURL: URL =
        switch Environment.get("SERVER") {
        case "Staging": try Servers.Server2.url()
        default: try Servers.Server1.url()
        }
    app.logger.info("Service registered on Server URL: \(serverURL)")
    try service.registerHandlers(on: transport, serverURL: serverURL)

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
    // OpenTelemetry
    // ================================
    let environment = OTelEnvironment.detected()
    let resourceDetection = OTelResourceDetection(detectors: [
        OTelProcessResourceDetector(),
        OTelEnvironmentResourceDetector(environment: environment),
        .manual(OTelResource(attributes: ["service.name": "CommandServer"])),
    ])
    let resource = await resourceDetection.resource(environment: environment, logLevel: .trace)
    let exporter = XRayOTelSpanExporter(
        client: ClientConfigurationDefaults.makeClient(),
        url: .init(string: "https://xray.ap-northeast-1.amazonaws.com/v1/traces")!,
    )
    let processor = OTelBatchSpanProcessor(
        exporter: exporter,
        configuration: .init(environment: environment),
    )
    let tracer = OTelTracer(
        idGenerator: OTelRandomIDGenerator(),
        sampler: OTelConstantSampler(isOn: true),
        propagator: OTelW3CPropagator(),
        processor: processor,
        environment: environment,
        resource: resource
    )
    InstrumentationSystem.bootstrap(tracer)

    app.middleware.use(TracingMiddleware())
    app.traceAutoPropagation = true
}
