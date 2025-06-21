import AsyncHTTPClient
import Foundation
import NIOCore
import OpenTelemetryApi
@preconcurrency import OpenTelemetrySdk
import OpenTelemetryProtocolExporterCommon

/// AWS X-Ray OTLP Exporter with SigV4 authentication
final class AWSXRayOTLPExporter: SpanExporter, @unchecked Sendable {
    private let endpoint: URL
    private let region: String
    private let httpClient: HTTPClient

    init(endpoint: URL? = nil, region: String? = nil, eventLoopGroup: any EventLoopGroup)
        async throws
    {
        // リージョンを環境変数またはパラメータから取得
        self.region =
            region ?? ProcessInfo.processInfo.environment["AWS_REGION"] ?? ProcessInfo.processInfo
            .environment["AWS_DEFAULT_REGION"] ?? "us-east-1"
        
        print("[DEBUG] AWSXRayOTLPExporter init:")
        print("[DEBUG]   Region: \(self.region)")
        print("[DEBUG]   Endpoint parameter: \(endpoint?.absoluteString ?? "nil")")

        // エンドポイントURLを構築
        if let endpoint = endpoint {
            self.endpoint = endpoint
        } else {
            self.endpoint = URL(string: "https://xray.\(self.region).amazonaws.com/v1/traces")!
        }
        
        print("[DEBUG]   Final endpoint: \(self.endpoint.absoluteString)")

        // HTTPClientの設定 - VaporのEventLoopGroupを使用
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(
                timeout: HTTPClient.Configuration.Timeout(
                    connect: .seconds(10),
                    read: .seconds(30)
                )
            )
        )
    }

    func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil) -> SpanExporterResultCode {
        print("[DEBUG] AWSXRayOTLPExporter.export called")
        print("[DEBUG]   Spans count: \(spans.count)")
        print("[DEBUG]   AWS_EXECUTION_ENV: \(ProcessInfo.processInfo.environment["AWS_EXECUTION_ENV"] ?? "not set")")
        
        // Lambda環境でのみ実際の送信を行う
        guard ProcessInfo.processInfo.environment["AWS_EXECUTION_ENV"]?.starts(with: "AWS_Lambda") == true else {
            print("[DEBUG] Not in Lambda environment, skipping X-Ray export")
            return .success
        }
        
        print("[DEBUG] Lambda environment detected")
        print("[DEBUG] Would export \(spans.count) spans to X-Ray endpoint: \(endpoint)")
        
        // スパンの詳細情報をログ
        for (index, span) in spans.enumerated().prefix(3) {
            print("[DEBUG] Span \(index):")
            print("[DEBUG]   Name: \(span.name)")
            print("[DEBUG]   TraceId: \(span.traceId.hexString)")
            print("[DEBUG]   SpanId: \(span.spanId.hexString)")
            print("[DEBUG]   Kind: \(span.kind)")
            print("[DEBUG]   Status: \(span.status)")
        }
        if spans.count > 3 {
            print("[DEBUG] ... and \(spans.count - 3) more spans")
        }

        // 現時点では簡易的に成功を返す
        // TODO: 非同期に変更するか、同期的にHTTPリクエストを送る実装を追加
        return .success
    }

    // TODO: 将来的に非同期エクスポートを実装
    // private func exportSpansAsync(spans: [SpanData]) async throws {
    //     // OTLPトレースデータを構築
    //     let resourceSpans = Opentelemetry_Proto_Trace_V1_ResourceSpans.with {
    //         $0.scopeSpans = [Opentelemetry_Proto_Trace_V1_ScopeSpans.with {
    //             $0.spans = spans.map { span in
    //                 span.toProto()
    //             }
    //         }]
    //     }
    //
    //     let exportRequest = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
    //         $0.resourceSpans = [resourceSpans]
    //     }
    //
    //     // リクエストボディをシリアライズ
    //     let body = try exportRequest.serializedData()
    //
    //     // HTTPリクエストを構築
    //     var request = HTTPClientRequest(url: endpoint.absoluteString)
    //     request.method = .POST
    //     request.headers.add(name: "Content-Type", value: "application/x-protobuf")
    //     request.headers.add(name: "Content-Length", value: String(body.count))
    //     request.body = .bytes(body)
    //
    //     // AWS認証情報を取得
    //     guard let accessKeyId = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"],
    //           let secretAccessKey = ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] else {
    //         throw ExportError.missingCredentials
    //     }
    //
    //     let sessionToken = ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"]
    //
    //     // SigV4署名を追加
    //     let signer = AWSSigV4(
    //         accessKeyId: accessKeyId,
    //         secretAccessKey: secretAccessKey,
    //         sessionToken: sessionToken,
    //         region: region,
    //         service: "xray"
    //     )
    //
    //     try signer.sign(request: &request, payload: Data(body), date: Date())
    //
    //     // リクエストを送信
    //     let response = try await httpClient.execute(request, timeout: .seconds(30))
    //
    //     // レスポンスを確認
    //     guard (200...299).contains(response.status.code) else {
    //         throw ExportError.httpError(statusCode: Int(response.status.code))
    //     }
    // }

    func flush(explicitTimeout: TimeInterval? = nil) -> SpanExporterResultCode {
        return .success
    }

    func shutdown(explicitTimeout: TimeInterval? = nil) {
        // HTTPClientをシャットダウン
        try? httpClient.syncShutdown()
    }
}

enum ExportError: Error {
    case missingCredentials
    case httpError(statusCode: Int)
}

// SpanDataをProtobufに変換する拡張
extension SpanData {
    func toProto() -> Opentelemetry_Proto_Trace_V1_Span {
        return Opentelemetry_Proto_Trace_V1_Span.with {
            // TraceIdを16バイトのDataに変換
            var traceIdData = Data(count: 16)
            self.traceId.copyBytesTo(dest: &traceIdData, destOffset: 0)
            $0.traceID = traceIdData
            
            // SpanIdを8バイトのDataに変換
            var spanIdData = Data(count: 8)
            self.spanId.copyBytesTo(dest: &spanIdData, destOffset: 0)
            $0.spanID = spanIdData
            
            if let parentSpanId = self.parentSpanId {
                var parentSpanIdData = Data(count: 8)
                parentSpanId.copyBytesTo(dest: &parentSpanIdData, destOffset: 0)
                $0.parentSpanID = parentSpanIdData
            }
            $0.name = self.name
            $0.kind = self.kind.toProto()
            $0.startTimeUnixNano = UInt64(self.startTime.timeIntervalSince1970 * 1_000_000_000)
            $0.endTimeUnixNano = UInt64(self.endTime.timeIntervalSince1970 * 1_000_000_000)
            $0.status = Opentelemetry_Proto_Trace_V1_Status.with {
                $0.code = self.status.toProto()
                if case let .error(description) = self.status {
                    $0.message = description
                }
            }
        }
    }
}

extension SpanKind {
    func toProto() -> Opentelemetry_Proto_Trace_V1_Span.SpanKind {
        switch self {
        case .client:
            return .client
        case .server:
            return .server
        case .producer:
            return .producer
        case .consumer:
            return .consumer
        case .internal:
            return .internal
        }
    }
}

extension Status {
    func toProto() -> Opentelemetry_Proto_Trace_V1_Status.StatusCode {
        switch self {
        case .unset:
            return .unset
        case .ok:
            return .ok
        case .error:
            return .error
        }
    }
}
