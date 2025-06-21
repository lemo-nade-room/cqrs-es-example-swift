import Foundation
import NIOCore
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk
import StdoutExporter
import Vapor

enum OpenTelemetryConfiguration {
    static func configureOpenTelemetry(
        serviceName: String, otlpEndpoint: String? = nil, eventLoopGroup: any EventLoopGroup
    ) async throws {
        print("[DEBUG] OpenTelemetryConfiguration.configureOpenTelemetry called")
        print("[DEBUG]   Service name: \(serviceName)")
        print("[DEBUG]   OTLP endpoint: \(otlpEndpoint ?? "nil")")
        
        let environmentName = (try? Environment.detect().name) ?? "development"
        print("[DEBUG]   Environment: \(environmentName)")
        
        let resource = Resource(attributes: [
            "service.name": AttributeValue.string(serviceName),
            "service.version": AttributeValue.string("1.0.0"),
            "deployment.environment": AttributeValue.string(environmentName),
        ])
        print("[DEBUG] Resource created")

        // Lambda環境かどうかを確認
        let isLambda = ProcessInfo.processInfo.environment["AWS_LAMBDA_FUNCTION_NAME"] != nil
        print("[DEBUG] Is Lambda: \(isLambda)")

        // エクスポーターの選択
        let spanExporter: any SpanExporter

        if let customEndpoint = otlpEndpoint {
            print("[DEBUG] Custom endpoint provided: \(customEndpoint)")
            if customEndpoint.starts(with: "https://xray.")
                && customEndpoint.contains(".amazonaws.com")
            {
                print("[DEBUG] Creating AWSXRayOTLPExporter for X-Ray endpoint")
                // X-RayのOTLPエンドポイントが指定された場合
                spanExporter = try await AWSXRayOTLPExporter(
                    endpoint: URL(string: customEndpoint)!,
                    eventLoopGroup: eventLoopGroup
                )
            } else {
                print("[DEBUG] Creating StdoutSpanExporter for custom endpoint")
                // カスタムエンドポイント（ローカルJaegerなど）
                // 現時点では標準出力エクスポーターを使用
                spanExporter = StdoutSpanExporter(
                    isDebug: true
                )
            }
        } else if isLambda {
            print("[DEBUG] Creating AWSXRayOTLPExporter for Lambda environment")
            // Lambda環境ではX-RayのOTLPエンドポイントを使用
            spanExporter = try await AWSXRayOTLPExporter(eventLoopGroup: eventLoopGroup)
        } else {
            print("[DEBUG] Creating StdoutSpanExporter for local development")
            // ローカル開発環境のデフォルト
            // 現時点では標準出力エクスポーターを使用
            spanExporter = StdoutSpanExporter(
                isDebug: true
            )
        }
        print("[DEBUG] Span exporter created: \(type(of: spanExporter))")

        let spanProcessor = BatchSpanProcessor(spanExporter: spanExporter)
        print("[DEBUG] BatchSpanProcessor created")

        let tracerProvider = TracerProviderBuilder()
            .add(spanProcessor: spanProcessor)
            .with(resource: resource)
            .build()
        print("[DEBUG] TracerProvider built")

        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
        print("[DEBUG] TracerProvider registered")
        print("[DEBUG] OpenTelemetryConfiguration.configureOpenTelemetry completed")
    }

    static func getTracer(instrumentationName: String) -> any Tracer {
        return OpenTelemetry.instance.tracerProvider.get(
            instrumentationName: instrumentationName,
            instrumentationVersion: "1.0.0"
        )
    }
}
