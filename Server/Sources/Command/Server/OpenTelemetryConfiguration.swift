import Foundation
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk
import StdoutExporter
import Vapor

enum OpenTelemetryConfiguration {
    static func configureOpenTelemetry(
        serviceName: String, otlpEndpoint: String? = nil, app: Application
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
                // X-RayのOTLPエンドポイントが指定された場合
                spanExporter = try await AWSXRayOTLPExporter(
                    endpoint: URL(string: customEndpoint)!,
                    eventLoopGroup: app.eventLoopGroup
                )
            } else {
                // カスタムエンドポイント（ローカルJaegerなど）
                // 現時点では標準出力エクスポーターを使用
                spanExporter = StdoutSpanExporter(
                    isDebug: true
                )
            }
        } else if isLambda {
            // Lambda環境ではX-RayのOTLPエンドポイントを使用
            spanExporter = try await AWSXRayOTLPExporter(eventLoopGroup: app.eventLoopGroup)
        } else {
            // ローカル開発環境のデフォルト
            // 現時点では標準出力エクスポーターを使用
            spanExporter = StdoutSpanExporter(
                isDebug: true
            )
        }

        let spanProcessor = BatchSpanProcessor(spanExporter: spanExporter)

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
