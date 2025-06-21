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
        print(
            "[DEBUG] ========== OpenTelemetryConfiguration.configureOpenTelemetry START ==========")
        print("[DEBUG] Parameters:")
        print("[DEBUG]   Service name: \(serviceName)")
        print("[DEBUG]   OTLP endpoint: \(otlpEndpoint ?? "nil")")

        let environmentName = (try? Environment.detect().name) ?? "development"
        print("[DEBUG] Detected environment: \(environmentName)")

        print("[DEBUG] Creating resource with attributes:")
        let resource = Resource(attributes: [
            "service.name": AttributeValue.string(serviceName),
            "service.version": AttributeValue.string("1.0.0"),
            "deployment.environment": AttributeValue.string(environmentName),
        ])
        print("[DEBUG] Resource created with attributes:")
        for (key, value) in resource.attributes {
            print("[DEBUG]   \(key): \(value)")
        }

        // Lambda環境かどうかを確認
        let isLambda = ProcessInfo.processInfo.environment["AWS_LAMBDA_FUNCTION_NAME"] != nil
        let lambdaFunctionName =
            ProcessInfo.processInfo.environment["AWS_LAMBDA_FUNCTION_NAME"] ?? "N/A"
        print("[DEBUG] Lambda detection:")
        print("[DEBUG]   Is Lambda: \(isLambda)")
        print("[DEBUG]   Lambda function name: \(lambdaFunctionName)")

        // エクスポーターの選択
        let spanExporter: any SpanExporter

        if let customEndpoint = otlpEndpoint {
            print("[DEBUG] Custom endpoint provided: \(customEndpoint)")
            if customEndpoint.starts(with: "https://xray.")
                && customEndpoint.contains(".amazonaws.com")
            {
                print("[DEBUG] ✅ Detected X-Ray endpoint pattern")
                print("[DEBUG] Creating AWSXRayOTLPExporter with:")
                print("[DEBUG]   Endpoint: \(customEndpoint)")
                print("[DEBUG]   Resource: \(resource.attributes)")
                // X-RayのOTLPエンドポイントが指定された場合
                spanExporter = try await AWSXRayOTLPExporter(
                    endpoint: URL(string: customEndpoint)!,
                    resource: resource,
                    eventLoopGroup: eventLoopGroup
                )
                print("[DEBUG] ✅ AWSXRayOTLPExporter created successfully")
            } else {
                print("[DEBUG] ⚠️ Non-X-Ray endpoint, falling back to StdoutSpanExporter")
                print("[DEBUG] Creating StdoutSpanExporter for custom endpoint")
                // カスタムエンドポイント（ローカルJaegerなど）
                // 現時点では標準出力エクスポーターを使用
                spanExporter = StdoutSpanExporter(
                    isDebug: true
                )
            }
        } else if isLambda {
            print("[DEBUG] 🚀 Lambda environment detected, creating AWSXRayOTLPExporter")
            // Lambda環境ではX-RayのOTLPエンドポイントを使用
            spanExporter = try await AWSXRayOTLPExporter(
                resource: resource, eventLoopGroup: eventLoopGroup)
            print("[DEBUG] ✅ AWSXRayOTLPExporter created for Lambda")
        } else {
            print("[DEBUG] 💻 Local development environment, creating StdoutSpanExporter")
            // ローカル開発環境のデフォルト
            // 現時点では標準出力エクスポーターを使用
            spanExporter = StdoutSpanExporter(
                isDebug: true
            )
        }
        print("[DEBUG] Selected span exporter: \(type(of: spanExporter))")

        let spanProcessor = BatchSpanProcessor(spanExporter: spanExporter)
        print("[DEBUG] BatchSpanProcessor created with exporter: \(type(of: spanExporter))")

        print("[DEBUG] Building TracerProvider")
        let tracerProvider = TracerProviderBuilder()
            .add(spanProcessor: spanProcessor)
            .with(resource: resource)
            .build()
        print("[DEBUG] ✅ TracerProvider built successfully")

        print("[DEBUG] Registering TracerProvider with OpenTelemetry")
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
        print("[DEBUG] ✅ TracerProvider registered successfully")

        // 登録確認
        let registeredProvider = OpenTelemetry.instance.tracerProvider
        print(
            "[DEBUG] Verification - TracerProvider is registered: \(type(of: registeredProvider))")

        print("[DEBUG] ========== OpenTelemetryConfiguration.configureOpenTelemetry END ==========")
        print("[DEBUG] ✅ OpenTelemetry is now configured and ready to trace!")
    }

    static func getTracer(instrumentationName: String) -> any Tracer {
        return OpenTelemetry.instance.tracerProvider.get(
            instrumentationName: instrumentationName,
            instrumentationVersion: "1.0.0"
        )
    }
}
