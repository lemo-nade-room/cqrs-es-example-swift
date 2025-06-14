import AWSSDKHTTPAuth
import ClientRuntime
import Foundation
import Logging
import OTel
import Smithy
@preconcurrency import SmithyHTTPAPI
import SmithyHTTPAuthAPI
import SmithyIdentity
import SmithyIdentityAPI
import SwiftProtobuf
import Tracing
import W3CTraceContext

/// AWS X-Ray の OTLP HTTP エンドポイントに Span を送る Exporter
actor XRayOTelSpanExporter: OTelSpanExporter {

    private let awsAccessKey: String
    private let awsSecretAccessKey: String
    private let awsSessionToken: String?
    private let region: String
    private let client: any HTTPClient
    private let customURL: URL?
    private let logger: Logger
    private var shutdowned = false

    // バッチサイズの上限（AWS X-Rayの制限に合わせて設定）
    private let maxBatchSize = 25
    // タイムアウト設定
    private let timeoutSeconds: TimeInterval = 10.0

    init(
        awsAccessKey: String,
        awsSecretAccessKey: String,
        awsSessionToken: String? = nil,
        region: String,
        client: any HTTPClient,
        customURL: URL? = nil,
        logger: Logger
    ) {
        self.awsAccessKey = awsAccessKey
        self.awsSecretAccessKey = awsSecretAccessKey
        self.awsSessionToken = awsSessionToken
        self.region = region
        self.client = client
        self.customURL = customURL
        self.logger = logger
    }

    func export(_ batch: some Collection<OTelFinishedSpan> & Sendable) async throws {
        guard !shutdowned else {
            logger.error("Attempted to export batch while already being shut down.")
            throw OTelSpanExporterAlreadyShutDownError()
        }
        guard let firstSpanResource = batch.first?.resource else { return }

        let traces = Opentelemetry_Proto_Trace_V1_TracesData.with { request in
            request.resourceSpans = [
                .with { resourceSpans in
                    resourceSpans.resource = .with { resource in
                        firstSpanResource.attributes.forEach { key, attribute in
                            guard let value = convertAttribute(attribute: attribute) else { return }
                            var protoAttribute = Opentelemetry_Proto_Common_V1_KeyValue()
                            protoAttribute.key = key
                            protoAttribute.value = value
                            resource.attributes.append(protoAttribute)
                        }
                    }

                    resourceSpans.scopeSpans = [
                        .with { scopeSpans in
                            scopeSpans.scope = .with { scope in
                                scope.name = "swift-otel"
                                scope.version = OTelLibrary.version
                            }
                            scopeSpans.spans = batch.map(convertOTelFinishedSpanToProto(span:))
                        }
                    ]
                }
            ]
        }

        let payload = try traces.serializedData()
        logger.debug("Serialized payload size: \(payload.count) bytes")

        // HTTPRequestBuilder を作り、SigV4 署名
        guard let host = url.host(percentEncoded: true) else {
            throw XRayOTelExporterError.invalidXRayURL(url)
        }

        let builder = HTTPRequestBuilder()
            .withMethod(.post)
            .withProtocol(url.scheme == "http" ? .http : .https)
            .withHost(host)
            .withPath(url.path)
            .withHeader(name: "Content-Type", value: "application/x-protobuf")
            .withBody(.data(payload))

        let signedRequest = try await sign(builder: builder)

        // 送信
        do {
            let response = try await client.send(request: signedRequest)
            let status = response.statusCode.rawValue

            logger.debug("Received response with status code: \(status)")

            guard (200..<300).contains(status) else {
                // エラーレスポンスの詳細をログに記録
                if let body = try? await response.body.readData() {
                    let errorMessage = String(data: body, encoding: .utf8) ?? "Unknown error"
                    logger.error(
                        "X-Ray OTLP endpoint returned error: \(status), message: \(errorMessage)")
                }
                throw XRayOTelExporterError.httpError(statusCode: status, response: response)
            }

            logger.debug("Successfully exported \(batch.count) spans to X-Ray")

        } catch {
            logger.error("Failed to export spans to X-Ray: \(error)")
            throw error
        }
    }

    func forceFlush() async throws {
        logger.debug("Force flush called")
    }

    func shutdown() async {
        logger.info("Shutting down X-Ray OTLP exporter")
        shutdowned = true
    }

    // MARK: – Private helpers

    private var identity: AWSCredentialIdentity {
        .init(
            accessKey: awsAccessKey,  // 修正: 正しいプロパティ名を使用
            secret: awsSecretAccessKey,
            sessionToken: awsSessionToken
        )
    }

    private var url: URL {
        customURL ?? URL(string: "https://xray.\(region).amazonaws.com/v1/traces")!
    }

    /// SigV4 署名を付与して最終的な HTTPRequest を返す
    private func sign(builder: SmithyHTTPAPI.HTTPRequestBuilder) async throws -> HTTPRequest {
        var props = Smithy.Attributes()
        props.set(key: SigningPropertyKeys.signingName, value: "xray")
        props.set(key: SigningPropertyKeys.signingRegion, value: region)
        props.set(key: SigningPropertyKeys.signingAlgorithm, value: SigningAlgorithm.sigv4)
        props.set(key: SigningPropertyKeys.bidirectionalStreaming, value: false)
        props.set(key: SigningPropertyKeys.unsignedBody, value: false)

        let signer = AWSSigV4Signer()
        let signedBuilder = try await signer.signRequest(
            requestBuilder: builder,
            identity: identity,
            signingProperties: props
        )
        return signedBuilder.build()
    }
}

// エラー定義の改善
enum XRayOTelExporterError: Error, Sendable {
    case invalidXRayURL(URL)
    case httpError(statusCode: Int, response: SmithyHTTPAPI.HTTPResponse)
    case serializationError(Error)
    case signingError(Error)
}

// Helper extension for chunking arrays
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Conversion Functions

func convertAttribute(attribute: SpanAttribute) -> Opentelemetry_Proto_Common_V1_AnyValue? {
    var anyValue = Opentelemetry_Proto_Common_V1_AnyValue()

    switch attribute {
    case .int32(let value):
        anyValue.intValue = Int64(value)

    case .int64(let value):
        anyValue.intValue = value

    case .double(let value):
        anyValue.doubleValue = value

    case .bool(let value):
        anyValue.boolValue = value

    case .string(let value):
        anyValue.stringValue = value

    case .stringConvertible(let value):
        anyValue.stringValue = String(describing: value)

    case .int32Array(let values):
        var arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue()
        arrayValue.values = values.map { value in
            var element = Opentelemetry_Proto_Common_V1_AnyValue()
            element.intValue = Int64(value)
            return element
        }
        anyValue.arrayValue = arrayValue

    case .int64Array(let values):
        var arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue()
        arrayValue.values = values.map { value in
            var element = Opentelemetry_Proto_Common_V1_AnyValue()
            element.intValue = value
            return element
        }
        anyValue.arrayValue = arrayValue

    case .doubleArray(let values):
        var arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue()
        arrayValue.values = values.map { value in
            var element = Opentelemetry_Proto_Common_V1_AnyValue()
            element.doubleValue = value
            return element
        }
        anyValue.arrayValue = arrayValue

    case .boolArray(let values):
        var arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue()
        arrayValue.values = values.map { value in
            var element = Opentelemetry_Proto_Common_V1_AnyValue()
            element.boolValue = value
            return element
        }
        anyValue.arrayValue = arrayValue

    case .stringArray(let values):
        var arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue()
        arrayValue.values = values.map { value in
            var element = Opentelemetry_Proto_Common_V1_AnyValue()
            element.stringValue = value
            return element
        }
        anyValue.arrayValue = arrayValue

    case .stringConvertibleArray(let values):
        var arrayValue = Opentelemetry_Proto_Common_V1_ArrayValue()
        arrayValue.values = values.map { value in
            var element = Opentelemetry_Proto_Common_V1_AnyValue()
            element.stringValue = String(describing: value)
            return element
        }
        anyValue.arrayValue = arrayValue

    default:
        logger.warning("Unknown SpanAttribute type encountered")
        return nil
    }

    return anyValue
}

func convertOTelFinishedSpanToProto(span: OTelFinishedSpan) -> Opentelemetry_Proto_Trace_V1_Span {
    var protoSpan = Opentelemetry_Proto_Trace_V1_Span()

    // Trace ID (16 bytes)
    protoSpan.traceID = span.spanContext.traceID.bytes.withUnsafeBytes { bytes in
        Data(bytes)
    }

    // Span ID (8 bytes)
    protoSpan.spanID = span.spanContext.spanID.bytes.withUnsafeBytes { bytes in
        Data(bytes)
    }

    // Parent Span ID (8 bytes, optional)
    if let parentSpanID = span.spanContext.parentSpanID {
        protoSpan.parentSpanID = parentSpanID.bytes.withUnsafeBytes { bytes in
            Data(bytes)
        }
    }

    // Trace State
    protoSpan.traceState = convertTraceState(span.spanContext.traceState)

    // Flags - combine trace flags with span flags
    protoSpan.flags = UInt32(span.spanContext.traceFlags.rawValue)

    // Operation name
    protoSpan.name = span.operationName

    // Span Kind
    protoSpan.kind = convertSpanKind(span.kind)

    // Timestamps
    protoSpan.startTimeUnixNano = span.startTimeNanosecondsSinceEpoch
    protoSpan.endTimeUnixNano = span.endTimeNanosecondsSinceEpoch

    // Attributes
    protoSpan.attributes = convertAttributes(span.attributes)

    // Status
    if let status = span.status {
        protoSpan.status = convertStatus(status)
    }

    // Events
    protoSpan.events = span.events.map(convertEvent)

    // Links
    protoSpan.links = span.links.map(convertLink)

    return protoSpan
}

// Helper function to convert TraceState to string
private func convertTraceState(_ traceState: TraceState) -> String {
    traceState
        .map { "\($0.vendor.rawValue)=\($0.value)" }
        .joined(separator: ",")
}

// Helper function to convert SpanKind
private func convertSpanKind(_ kind: Tracing.SpanKind) -> Opentelemetry_Proto_Trace_V1_Span.SpanKind
{
    switch kind {
    case .internal:
        return .internal
    case .server:
        return .server
    case .client:
        return .client
    case .producer:
        return .producer
    case .consumer:
        return .consumer
    }
}

// Helper function to convert SpanStatus
private func convertStatus(_ status: SpanStatus) -> Opentelemetry_Proto_Trace_V1_Status {
    var protoStatus = Opentelemetry_Proto_Trace_V1_Status()

    switch status.code {
    case .ok:
        protoStatus.code = .ok
    case .error:
        protoStatus.code = .error
    }

    if let message = status.message {
        protoStatus.message = message
    }

    return protoStatus
}

// Helper function to convert SpanAttributes to array of KeyValue
private func convertAttributes(_ attributes: SpanAttributes)
    -> [Opentelemetry_Proto_Common_V1_KeyValue]
{
    var keyValues: [Opentelemetry_Proto_Common_V1_KeyValue] = []

    attributes.forEach { key, attribute in
        guard let value = convertAttribute(attribute: attribute) else { return }
        var keyValue = Opentelemetry_Proto_Common_V1_KeyValue()
        keyValue.key = key
        keyValue.value = value
        keyValues.append(keyValue)
    }

    return keyValues
}

// Helper function to convert SpanEvent
private func convertEvent(_ event: SpanEvent) -> Opentelemetry_Proto_Trace_V1_Span.Event {
    var protoEvent = Opentelemetry_Proto_Trace_V1_Span.Event()

    protoEvent.name = event.name
    protoEvent.timeUnixNano = event.nanosecondsSinceEpoch
    protoEvent.attributes = convertAttributes(event.attributes)

    return protoEvent
}

// Helper function to convert SpanLink
private func convertLink(_ link: Tracing.SpanLink) -> Opentelemetry_Proto_Trace_V1_Span.Link {
    var protoLink = Opentelemetry_Proto_Trace_V1_Span.Link()

    // Extract OTelSpanContext from the link's service context
    if let spanContext = link.context.spanContext {
        protoLink.traceID = spanContext.traceID.bytes.withUnsafeBytes { buffer in
            Data(buffer)
        }
        protoLink.spanID = spanContext.spanID.bytes.withUnsafeBytes { buffer in
            Data(buffer)
        }
        protoLink.traceState = convertTraceState(spanContext.traceState)
        protoLink.flags = UInt32(spanContext.traceFlags.rawValue)
    }

    protoLink.attributes = convertAttributes(link.attributes)

    return protoLink
}

// グローバルなロガーインスタンス（必要に応じて設定）
private let logger = Logger(label: "XRayOTelExporter")
