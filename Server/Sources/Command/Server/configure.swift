import ClientRuntime
import OTel
import OpenAPIRuntime
import OpenAPIVapor
import Tracing
import Vapor

func configure(_ app: Application) async throws {
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
        awsAccessKey: Environment.get("AWS_ACCESS_KEY_ID") ?? "",
        awsSecretAccessKey: Environment.get("AWS_SECRET_ACCESS_KEY") ?? "",
        awsSessionToken: Environment.get("AWS_SESSION_TOKEN"),
        region: Environment.get("AWS_REGION") ?? "ap-northeast-1",
        client: ClientConfigurationDefaults.makeClient(),
        customURL: Environment.get("AWS_XRAY_URL").flatMap(URL.init(string:)),
        logger: app.logger
    )
    let processor = OTelSimpleSpanProcessor(exporter: exporter)
    let tracer = OTelTracer(
        idGenerator: OTelRandomIDGenerator(),
        sampler: OTelConstantSampler(isOn: true),
        propagator: XRayOTelPropagator(logger: app.logger),
        processor: processor,
        environment: environment,
        resource: resource
    )
    InstrumentationSystem.bootstrap(tracer)

    app.middleware.use(TracingMiddleware())
    app.traceAutoPropagation = true

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
    // OpenAPI Vapor Transport
    // ================================
    app.middleware.use(VaporRequestMiddleware())
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
