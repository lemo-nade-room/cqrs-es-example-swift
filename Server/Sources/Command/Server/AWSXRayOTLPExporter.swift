import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
@preconcurrency import OpenTelemetrySdk

/// AWS X-Ray OTLP Exporter with SigV4 authentication
final class AWSXRayOTLPExporter: SpanExporter, @unchecked Sendable {
    private let endpoint: URL
    private let region: String
    private let httpClient: HTTPClient
    private let resource: Resource

    init(
        endpoint: URL? = nil, resource: Resource? = nil, region: String? = nil,
        eventLoopGroup: any EventLoopGroup
    )
        async throws
    {
        // リージョンを環境変数またはパラメータから取得
        self.region =
            region ?? ProcessInfo.processInfo.environment["AWS_REGION"] ?? ProcessInfo.processInfo
            .environment["AWS_DEFAULT_REGION"] ?? "us-east-1"

        print("🏗️ Initializing AWSXRayOTLPExporter | Region: \(self.region)")

        // エンドポイントURLを構築
        if let endpoint = endpoint {
            // カスタムエンドポイントが/v1/tracesで終わっていない場合は追加
            if !endpoint.absoluteString.hasSuffix("/v1/traces") {
                self.endpoint = endpoint.appendingPathComponent("v1/traces")
            } else {
                self.endpoint = endpoint
            }
        } else {
            self.endpoint = URL(string: "https://xray.\(self.region).amazonaws.com/v1/traces")!
        }

        // リソースの設定
        if let resource = resource {
            self.resource = resource
        } else {
            // デフォルトリソースまたは環境変数から構築
            var attributes: [String: AttributeValue] = [:]

            // OTEL_RESOURCE_ATTRIBUTESから属性を読み込む
            if let resourceAttrs = ProcessInfo.processInfo.environment["OTEL_RESOURCE_ATTRIBUTES"] {
                for pair in resourceAttrs.split(separator: ",") {
                    let keyValue = pair.split(separator: "=", maxSplits: 1)
                    if keyValue.count == 2 {
                        let key = String(keyValue[0]).trimmingCharacters(in: .whitespaces)
                        let value = String(keyValue[1]).trimmingCharacters(in: .whitespaces)
                        attributes[key] = AttributeValue.string(value)
                    }
                }
            }

            // service.nameがない場合はデフォルトを設定
            if attributes["service.name"] == nil {
                attributes["service.name"] = AttributeValue.string("unknown-service")
            }

            self.resource = Resource(attributes: attributes)
        }

        let serviceName = self.resource.attributes["service.name"]?.description ?? "unknown"
        print("📍 Endpoint: \(self.endpoint.absoluteString) | Service: \(serviceName)")

        // HTTPClientの設定 - VaporのEventLoopGroupを使用
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(
                timeout: HTTPClient.Configuration.Timeout(
                    connect: .seconds(5),
                    read: .seconds(10)
                )
            )
        )
    }

    func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil) -> SpanExporterResultCode {
        // Lambda環境でのみ実際の送信を行う
        guard
            ProcessInfo.processInfo.environment["AWS_EXECUTION_ENV"]?.starts(with: "AWS_Lambda")
                == true
        else {
            return .success
        }

        print("📦 Exporting \(spans.count) spans to X-Ray")
        if let firstSpan = spans.first {
            print(
                "📡 First span: TraceID=\(firstSpan.traceId.hexString), "
                    + "SpanID=\(firstSpan.spanId.hexString), Name=\(firstSpan.name)"
            )
        }

        // 早期にProtobufに変換してSendableな形式にする
        do {
            let resourceSpans = Opentelemetry_Proto_Trace_V1_ResourceSpans.with {
                // リソース情報を設定
                $0.resource = Opentelemetry_Proto_Resource_V1_Resource.with {
                    $0.attributes = self.resource.attributes.map { key, value in
                        return Opentelemetry_Proto_Common_V1_KeyValue.with {
                            $0.key = key
                            $0.value = value.toProto()
                        }
                    }
                }

                $0.scopeSpans = [
                    Opentelemetry_Proto_Trace_V1_ScopeSpans.with {
                        $0.spans = spans.map { span in
                            span.toProto()
                        }
                    }
                ]
            }

            let exportRequest =
                Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
                    $0.resourceSpans = [resourceSpans]
                }

            // リクエストボディをシリアライズ
            let body = try exportRequest.serializedData()
            let spanCount = spans.count

            // バックグラウンドで非同期送信（Fire-and-forget）
            Task.detached { [weak self] in
                guard let self = self else { return }

                do {
                    try await self.sendHTTPRequest(body: body)
                    print("✅ Exported \(spanCount) spans to X-Ray successfully")
                } catch {
                    print("❌ X-Ray export failed: \(error)")
                    if let exportError = error as? ExportError {
                        switch exportError {
                        case .missingCredentials:
                            print("❌ Missing AWS credentials")
                        case .httpError(let statusCode):
                            print("❌ HTTP error with status code: \(statusCode)")
                        }
                    }
                }
            }
        } catch {
            print("❌ Failed to serialize spans: \(error)")
            return .failure
        }

        // 即座に成功を返す（Fire-and-forget方式）
        return .success
    }

    private func sendHTTPRequest(body: Data) async throws {
        // HTTPリクエストを構築
        var request = HTTPClientRequest(url: endpoint.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-protobuf")
        request.headers.add(name: "Content-Length", value: String(body.count))

        // AWS認証情報を取得
        guard let accessKeyId = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"],
            let secretAccessKey = ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"]
        else {
            throw ExportError.missingCredentials
        }

        let sessionToken = ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"]

        // SigV4署名を追加
        let signer = AWSSigV4(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            region: region,
            service: "xray"
        )

        let signDate = Date()
        try signer.sign(request: &request, payload: Data(body), date: signDate)
        print("📡 Sending to: \(endpoint.absoluteString)")
        print("🔐 Authorization header present: \(request.headers["Authorization"].first != nil)")
        print("📊 Body size: \(body.count) bytes")

        // リクエストボディを設定
        request.body = .bytes(ByteBuffer(data: body))

        // リクエストを送信
        let response = try await httpClient.execute(request, timeout: .seconds(30))

        // レスポンスステータスをチェック
        if (200...299).contains(response.status.code) {
            print("✅ X-Ray API response: \(response.status.code)")
        } else {
            // エラーの詳細を取得
            if let bodyData = try? await response.body.collect(upTo: 1024 * 1024),
                let errorMessage = bodyData.getString(at: 0, length: bodyData.readableBytes)
            {
                print("❌ X-Ray API error (\(response.status.code)): \(errorMessage)")
                print("❌ Request URL: \(endpoint.absoluteString)")
                print("❌ Request headers: \(request.headers)")
            }
            throw ExportError.httpError(statusCode: Int(response.status.code))
        }
    }

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
                if case .error(let description) = self.status {
                    $0.message = description
                }
            }
            // 属性を追加
            $0.attributes = self.attributes.map { key, value in
                return Opentelemetry_Proto_Common_V1_KeyValue.with {
                    $0.key = key
                    $0.value = value.toProto()
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

extension AttributeValue {
    func toProto() -> Opentelemetry_Proto_Common_V1_AnyValue {
        return Opentelemetry_Proto_Common_V1_AnyValue.with {
            switch self {
            case .string(let value):
                $0.stringValue = value
            case .int(let value):
                $0.intValue = Int64(value)
            case .double(let value):
                $0.doubleValue = value
            case .bool(let value):
                $0.boolValue = value
            case .array(let values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.values.map { $0.toProto() }
                }
            case .set(let values):
                // AttributeSetのlabelsを配列に変換
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.labels.values.map { $0.toProto() }
                }
            // Deprecated cases
            case .stringArray(let values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.map { AttributeValue.string($0).toProto() }
                }
            case .boolArray(let values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.map { AttributeValue.bool($0).toProto() }
                }
            case .intArray(let values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.map { AttributeValue.int($0).toProto() }
                }
            case .doubleArray(let values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.map { AttributeValue.double($0).toProto() }
                }
            }
        }
    }
}
