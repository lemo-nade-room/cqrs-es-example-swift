import Foundation
import NIOCore
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk
import StdoutExporter
import Tracing
import Vapor

enum OpenTelemetryConfiguration {
    static func configureOpenTelemetry(
        serviceName: String, otlpEndpoint: String? = nil, eventLoopGroup: any EventLoopGroup
    ) async throws {
        let environmentName = (try? Environment.detect().name) ?? "development"

        let resource = Resource(attributes: [
            "service.name": AttributeValue.string(serviceName),
            "service.version": AttributeValue.string("1.0.0"),
            "deployment.environment": AttributeValue.string(environmentName),
        ])

        // Lambda環境かどうかを確認
        let isLambda = ProcessInfo.processInfo.environment["AWS_LAMBDA_FUNCTION_NAME"] != nil

        // エクスポーターの選択
        let spanExporter: any SpanExporter

        if let customEndpoint = otlpEndpoint {
            if customEndpoint.starts(with: "https://xray.")
                && customEndpoint.contains(".amazonaws.com")
            {
                spanExporter = try await AWSXRayOTLPExporter(
                    endpoint: URL(string: customEndpoint)!,
                    resource: resource,
                    eventLoopGroup: eventLoopGroup
                )
                print("🔧 X-Ray exporter configured: \(customEndpoint)")
            } else if customEndpoint.starts(with: "http://")
                && (customEndpoint.contains(":4318") || customEndpoint.contains("jaeger"))
            {
                // Jaeger OTLP HTTP endpoint
                spanExporter = try await JaegerOTLPExporter(
                    endpoint: URL(string: customEndpoint)!,
                    resource: resource,
                    eventLoopGroup: eventLoopGroup
                )
                print("🔧 Jaeger OTLP HTTP exporter configured: \(customEndpoint)")
            } else {
                spanExporter = StdoutSpanExporter(
                    isDebug: true
                )
                print("🔧 Stdout exporter configured (custom endpoint not supported)")
            }
        } else if isLambda {
            spanExporter = try await AWSXRayOTLPExporter(
                resource: resource, eventLoopGroup: eventLoopGroup)
            print("🔧 X-Ray exporter configured for Lambda")
        } else {
            spanExporter = StdoutSpanExporter(
                isDebug: true
            )
            print("🔧 Stdout exporter configured for local development")
        }

        let spanProcessor = BatchSpanProcessor(spanExporter: spanExporter)
        let tracerProvider = TracerProviderBuilder()
            .add(spanProcessor: spanProcessor)
            .with(resource: resource)
            .build()

        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
    }

    static func getTracer(instrumentationName: String) -> any OpenTelemetryApi.Tracer {
        return OpenTelemetry.instance.tracerProvider.get(
            instrumentationName: instrumentationName,
            instrumentationVersion: "1.0.0"
        )
    }
}
