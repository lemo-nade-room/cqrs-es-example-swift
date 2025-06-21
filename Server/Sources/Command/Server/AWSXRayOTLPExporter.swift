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

        print("[DEBUG] ========== AWSXRayOTLPExporter init START ==========")
        print("[DEBUG] Region: \(self.region)")
        print("[DEBUG] Endpoint parameter: \(endpoint?.absoluteString ?? "nil")")
        print("[DEBUG] Environment variables:")
        print(
            "[DEBUG]   AWS_REGION: \(ProcessInfo.processInfo.environment["AWS_REGION"] ?? "not set")"
        )
        print(
            "[DEBUG]   AWS_DEFAULT_REGION: \(ProcessInfo.processInfo.environment["AWS_DEFAULT_REGION"] ?? "not set")"
        )
        print(
            "[DEBUG]   OTEL_RESOURCE_ATTRIBUTES: \(ProcessInfo.processInfo.environment["OTEL_RESOURCE_ATTRIBUTES"] ?? "not set")"
        )

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

        print("[DEBUG] Final endpoint: \(self.endpoint.absoluteString)")

        // リソースの設定
        if let resource = resource {
            print("[DEBUG] Resource provided in init")
            self.resource = resource
        } else {
            print("[DEBUG] Resource not provided, building from environment")
            // デフォルトリソースまたは環境変数から構築
            var attributes: [String: AttributeValue] = [:]

            // OTEL_RESOURCE_ATTRIBUTESから属性を読み込む
            if let resourceAttrs = ProcessInfo.processInfo.environment["OTEL_RESOURCE_ATTRIBUTES"] {
                print("[DEBUG] Parsing OTEL_RESOURCE_ATTRIBUTES: \(resourceAttrs)")
                for pair in resourceAttrs.split(separator: ",") {
                    let keyValue = pair.split(separator: "=", maxSplits: 1)
                    if keyValue.count == 2 {
                        let key = String(keyValue[0]).trimmingCharacters(in: .whitespaces)
                        let value = String(keyValue[1]).trimmingCharacters(in: .whitespaces)
                        attributes[key] = AttributeValue.string(value)
                        print("[DEBUG]   Parsed attribute: \(key) = \(value)")
                    }
                }
            } else {
                print("[DEBUG] OTEL_RESOURCE_ATTRIBUTES not found")
            }

            // service.nameがない場合はデフォルトを設定
            if attributes["service.name"] == nil {
                print("[DEBUG] service.name not found, setting default")
                attributes["service.name"] = AttributeValue.string("unknown-service")
            }

            self.resource = Resource(attributes: attributes)
        }

        print("[DEBUG] Final resource attributes: \(self.resource.attributes)")
        print("[DEBUG] Resource attributes count: \(self.resource.attributes.count)")

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
        print("[DEBUG] HTTPClient configured with timeout: connect=10s, read=30s")
        print("[DEBUG] ========== AWSXRayOTLPExporter init END ==========")
    }

    func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil) -> SpanExporterResultCode {
        print("[DEBUG] ========== AWSXRayOTLPExporter.export START ==========")
        print("[DEBUG] Spans count: \(spans.count)")
        print(
            "[DEBUG] AWS_EXECUTION_ENV: \(ProcessInfo.processInfo.environment["AWS_EXECUTION_ENV"] ?? "not set")"
        )
        print(
            "[DEBUG] _X_AMZN_TRACE_ID: \(ProcessInfo.processInfo.environment["_X_AMZN_TRACE_ID"] ?? "not set")"
        )
        print("[DEBUG] Endpoint: \(self.endpoint.absoluteString)")
        print("[DEBUG] Region: \(self.region)")

        // Lambda環境でのみ実際の送信を行う
        guard
            ProcessInfo.processInfo.environment["AWS_EXECUTION_ENV"]?.starts(with: "AWS_Lambda")
                == true
        else {
            print("[DEBUG] Not in Lambda environment, skipping X-Ray export")
            print("[DEBUG] ========== AWSXRayOTLPExporter.export END (skipped) ==========")
            return .success
        }

        print("[DEBUG] Lambda environment detected - proceeding with export")

        // スパンの詳細情報をログ
        print("[DEBUG] First 3 spans details:")
        for (index, span) in spans.enumerated().prefix(3) {
            print("[DEBUG] Span \(index):")
            print("[DEBUG]   Name: \(span.name)")
            print("[DEBUG]   TraceId: \(span.traceId.hexString)")
            print("[DEBUG]   SpanId: \(span.spanId.hexString)")
            print("[DEBUG]   ParentSpanId: \(span.parentSpanId?.hexString ?? "nil")")
            print("[DEBUG]   Kind: \(span.kind)")
            print("[DEBUG]   Status: \(span.status)")
            print("[DEBUG]   Start time: \(span.startTime)")
            print("[DEBUG]   End time: \(span.endTime)")
            print("[DEBUG]   Attributes count: \(span.attributes.count)")
            if span.attributes.count > 0 {
                print("[DEBUG]   First 3 attributes:")
                for (key, value) in span.attributes.prefix(3) {
                    print("[DEBUG]     \(key): \(value)")
                }
            }
        }
        if spans.count > 3 {
            print("[DEBUG] ... and \(spans.count - 3) more spans")
        }

        // 早期にProtobufに変換してSendableな形式にする
        print("[DEBUG] Converting spans to Protobuf")
        do {
            print("[DEBUG] Building ResourceSpans with resource attributes:")
            for (key, value) in self.resource.attributes {
                print("[DEBUG]   Resource attr: \(key) = \(value)")
            }

            let resourceSpans = Opentelemetry_Proto_Trace_V1_ResourceSpans.with {
                // リソース情報を設定
                $0.resource = Opentelemetry_Proto_Resource_V1_Resource.with {
                    $0.attributes = self.resource.attributes.map { key, value in
                        print("[DEBUG]     Converting resource attribute: \(key)")
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
            print("[DEBUG] ResourceSpans built successfully")

            let exportRequest =
                Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
                    $0.resourceSpans = [resourceSpans]
                }
            print("[DEBUG] ExportTraceServiceRequest built")

            // リクエストボディをシリアライズ
            let body = try exportRequest.serializedData()
            let spanCount = spans.count
            print("[DEBUG] Protobuf serialized successfully, body size: \(body.count) bytes")

            // バックグラウンドで非同期送信（Fire-and-forget）
            print("[DEBUG] Starting fire-and-forget async task")
            Task.detached { [weak self] in
                guard let self = self else {
                    print("[DEBUG] Self is nil in detached task")
                    return
                }

                print("[DEBUG] Detached task started")
                do {
                    try await self.sendHTTPRequest(body: body)
                    print("[DEBUG] ✅ Successfully exported \(spanCount) spans to X-Ray")
                } catch {
                    print("[DEBUG] ❌ Failed to export spans: \(error)")
                    print("[DEBUG] Error type: \(type(of: error))")
                    print("[DEBUG] Error details: \(String(describing: error))")
                }
                print("[DEBUG] Detached task completed")
            }
            print("[DEBUG] Fire-and-forget task launched")
        } catch {
            print("[DEBUG] ❌ Failed to serialize spans: \(error)")
            print("[DEBUG] Error type: \(type(of: error))")
            print("[DEBUG] ========== AWSXRayOTLPExporter.export END (failure) ==========")
            return .failure
        }

        // 即座に成功を返す（Fire-and-forget方式）
        print("[DEBUG] Returning success immediately (fire-and-forget)")
        print("[DEBUG] ========== AWSXRayOTLPExporter.export END (success) ==========")
        return .success
    }

    private func sendHTTPRequest(body: Data) async throws {
        print("[DEBUG] ========== sendHTTPRequest START ==========")
        print("[DEBUG] Body size: \(body.count) bytes")
        print("[DEBUG] Endpoint URL: \(endpoint.absoluteString)")

        // HTTPリクエストを構築
        print("[DEBUG] Building HTTP request")
        var request = HTTPClientRequest(url: endpoint.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-protobuf")
        request.headers.add(name: "Content-Length", value: String(body.count))
        print("[DEBUG] Request method: POST")
        print("[DEBUG] Request headers before signing:")
        for (name, value) in request.headers {
            print("[DEBUG]   \(name): \(value)")
        }

        // AWS認証情報を取得
        print("[DEBUG] Checking AWS credentials")
        guard let accessKeyId = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"],
            let secretAccessKey = ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"]
        else {
            print("[DEBUG] ❌ Missing AWS credentials")
            print(
                "[DEBUG]   AWS_ACCESS_KEY_ID: \(ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] != nil ? "present" : "missing")"
            )
            print(
                "[DEBUG]   AWS_SECRET_ACCESS_KEY: \(ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] != nil ? "present" : "missing")"
            )
            throw ExportError.missingCredentials
        }

        let sessionToken = ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"]
        print("[DEBUG] AWS credentials found:")
        print("[DEBUG]   Access Key ID: \(String(accessKeyId.prefix(10)))*****")
        print("[DEBUG]   Session Token present: \(sessionToken != nil)")

        // SigV4署名を追加
        print("[DEBUG] Creating SigV4 signer")
        let signer = AWSSigV4(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            region: region,
            service: "xray"
        )

        print("[DEBUG] Signing request with SigV4")
        let currentDate = Date()
        print("[DEBUG] Current date for signing: \(currentDate)")
        try signer.sign(request: &request, payload: Data(body), date: currentDate)
        print("[DEBUG] SigV4 signature added successfully")
        print("[DEBUG] Request headers after signing:")
        for (name, value) in request.headers {
            if name.lowercased().contains("authorization") {
                print("[DEBUG]   \(name): [REDACTED]")
            } else {
                print("[DEBUG]   \(name): \(value)")
            }
        }

        // リクエストボディを設定
        request.body = .bytes(ByteBuffer(data: body))
        print("[DEBUG] Request body set")

        // リクエストを送信
        print("[DEBUG] Executing HTTP request to \(endpoint.absoluteString)")
        let startTime = Date()
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        print("[DEBUG] HTTP request completed in \(duration) seconds")
        print("[DEBUG] Response status: \(response.status.code)")
        print("[DEBUG] Response headers:")
        for (name, value) in response.headers {
            print("[DEBUG]   \(name): \(value)")
        }

        // レスポンスボディを読み取る
        do {
            let bodyData = try await response.body.collect(upTo: 1024 * 1024)  // 1MB limit
            print("[DEBUG] Response body size: \(bodyData.readableBytes) bytes")

            if bodyData.readableBytes > 0 {
                if let responseString = bodyData.getString(at: 0, length: bodyData.readableBytes) {
                    print("[DEBUG] Response body (as string): \(responseString)")
                } else {
                    let responseData =
                        bodyData.getData(at: 0, length: min(100, bodyData.readableBytes)) ?? Data()
                    print(
                        "[DEBUG] Response body (hex): \(responseData.map { String(format: "%02x", $0) }.joined())"
                    )
                }
            } else {
                print("[DEBUG] Response body is empty")
            }
        } catch {
            print("[DEBUG] Failed to read response body: \(error)")
        }

        // レスポンスを確認
        guard (200...299).contains(response.status.code) else {
            print("[DEBUG] ❌ HTTP error response: \(response.status.code)")
            print("[DEBUG] ========== sendHTTPRequest END (error) ==========")
            throw ExportError.httpError(statusCode: Int(response.status.code))
        }

        print("[DEBUG] ✅ Successfully sent spans to X-Ray")
        print("[DEBUG] ========== sendHTTPRequest END (success) ==========")
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

extension AttributeValue {
    func toProto() -> Opentelemetry_Proto_Common_V1_AnyValue {
        return Opentelemetry_Proto_Common_V1_AnyValue.with {
            switch self {
            case let .string(value):
                $0.stringValue = value
            case let .int(value):
                $0.intValue = Int64(value)
            case let .double(value):
                $0.doubleValue = value
            case let .bool(value):
                $0.boolValue = value
            case let .array(values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.values.map { $0.toProto() }
                }
            case let .set(values):
                // AttributeSetのlabelsを配列に変換
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.labels.values.map { $0.toProto() }
                }
            // Deprecated cases
            case let .stringArray(values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.map { AttributeValue.string($0).toProto() }
                }
            case let .boolArray(values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.map { AttributeValue.bool($0).toProto() }
                }
            case let .intArray(values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.map { AttributeValue.int($0).toProto() }
                }
            case let .doubleArray(values):
                $0.arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue.with {
                    $0.values = values.map { AttributeValue.double($0).toProto() }
                }
            }
        }
    }
}
