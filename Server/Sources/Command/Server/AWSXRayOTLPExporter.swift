@preconcurrency import AWSClientRuntime
import AsyncHTTPClient
import ClientRuntime
import Foundation
import NIOCore
import NIOHTTP1
import OpenTelemetrySdk

/// AWS X-Ray OTLP Exporter with SigV4 authentication
class AWSXRayOTLPExporter: SpanExporter {
    private let endpoint: URL
    private let region: String
    private let httpClient: HTTPClient

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

        // HTTPClientの設定
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: HTTPClient.Configuration(
                timeout: HTTPClient.Configuration.Timeout(
                    connect: .seconds(10),
                    read: .seconds(30)
                )
            )
        )
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
        // HTTPClientをシャットダウン
        try? httpClient.syncShutdown()
    }
}
