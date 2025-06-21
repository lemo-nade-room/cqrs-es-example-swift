import Foundation
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import Vapor

enum OpenTelemetryConfiguration {
    static func configureOpenTelemetry(serviceName: String, otlpEndpoint: String = "http://localhost:4318") {
        let environmentName = (try? Environment.detect().name) ?? "development"
        let resource = Resource(attributes: [
            "service.name": AttributeValue.string(serviceName),
            "service.version": AttributeValue.string("1.0.0"),
            "deployment.environment": AttributeValue.string(environmentName)
        ])
        
        let otlpHttpExporter = OtlpHttpTraceExporter(
            endpoint: URL(string: "\(otlpEndpoint)/v1/traces")!
        )
        
        let spanProcessor = BatchSpanProcessor(spanExporter: otlpHttpExporter)
        
        let tracerProvider = TracerProviderBuilder()
            .add(spanProcessor: spanProcessor)
            .with(resource: resource)
            .build()
        
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
    }
    
    static func getTracer(instrumentationName: String) -> any Tracer {
        return OpenTelemetry.instance.tracerProvider.get(
            instrumentationName: instrumentationName,
            instrumentationVersion: "1.0.0"
        )
    }
}