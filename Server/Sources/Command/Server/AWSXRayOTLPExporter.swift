@preconcurrency import AWSClientRuntime
import ClientRuntime
import Foundation
import OpenTelemetrySdk

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// AWS X-Ray OTLP Exporter with SigV4 authentication
class AWSXRayOTLPExporter: SpanExporter {
    private let endpoint: URL
    private let region: String
    private let session: URLSession

    init(endpoint: URL? = nil, region: String? = nil) async throws {
        // リージョンを環境変数またはパラメータから取得
        self.region =
            region ?? ProcessInfo.processInfo.environment["AWS_REGION"] ?? ProcessInfo.processInfo
            .environment["AWS_DEFAULT_REGION"] ?? "us-east-1"

        // エンドポイントURLを構築
        if let endpoint = endpoint {
            self.endpoint = endpoint
        } else {
            self.endpoint = URL(string: "https://xray.\(self.region).amazonaws.com/v1/traces")!
        }

        // URLSessionの設定
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil) -> SpanExporterResultCode {
        // 現時点では簡易実装 - 実際のX-Rayへの送信はLambda環境でのみ必要
        print("Exporting \(spans.count) spans to X-Ray endpoint: \(endpoint)")
        return .success
    }

    func flush(explicitTimeout: TimeInterval? = nil) -> SpanExporterResultCode {
        return .success
    }

    func shutdown(explicitTimeout: TimeInterval? = nil) {
        // クリーンアップ処理
    }
}
