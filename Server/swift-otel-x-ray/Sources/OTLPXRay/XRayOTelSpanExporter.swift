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

// MARK: - Protocols for Testability

/// Protocol for AWS signing functionality
protocol AWSSigner: Sendable {
    func signRequest(
        requestBuilder: HTTPRequestBuilder,
        identity: AWSCredentialIdentity,
        signingProperties: Smithy.Attributes
    ) async throws -> HTTPRequestBuilder
}

// Default implementation
struct DefaultAWSSigner: AWSSigner {
    private let signer = AWSSigV4Signer()

    func signRequest(
        requestBuilder: HTTPRequestBuilder,
        identity: AWSCredentialIdentity,
        signingProperties: Smithy.Attributes
    ) async throws -> HTTPRequestBuilder {
        try await signer.signRequest(
            requestBuilder: requestBuilder,
            identity: identity,
            signingProperties: signingProperties
        )
    }
}

/// Protocol for trace data serialization
protocol TraceSerializer: Sendable {
    func serialize(_ traces: Opentelemetry_Proto_Trace_V1_TracesData) throws -> Data
}

struct DefaultTraceSerializer: TraceSerializer {
    func serialize(_ traces: Opentelemetry_Proto_Trace_V1_TracesData) throws -> Data {
        try traces.serializedData()
    }
}

// MARK: - Configuration

public struct XRayOTelExporterConfiguration: Sendable {
    let awsAccessKey: String
    let awsSecretAccessKey: String
    let awsSessionToken: String?
    let region: String
    let customURL: URL?
    let maxBatchSize: Int
    let timeoutSeconds: TimeInterval

    public init(
        awsAccessKey: String,
        awsSecretAccessKey: String,
        awsSessionToken: String? = nil,
        region: String,
        customURL: URL? = nil,
        maxBatchSize: Int = 25,
        timeoutSeconds: TimeInterval = 10.0
    ) {
        self.awsAccessKey = awsAccessKey
        self.awsSecretAccessKey = awsSecretAccessKey
        self.awsSessionToken = awsSessionToken
        self.region = region
        self.customURL = customURL
        self.maxBatchSize = maxBatchSize
        self.timeoutSeconds = timeoutSeconds
    }

    var url: URL {
        customURL ?? URL(string: "https://xray.\(region).amazonaws.com/v1/traces")!
    }

    var identity: AWSCredentialIdentity {
        .init(
            accessKey: awsAccessKey,
            secret: awsSecretAccessKey,
            sessionToken: awsSessionToken
        )
    }
}

// MARK: - Main Exporter

/// AWS X-Ray の OTLP HTTP エンドポイントに Span を送る Exporter
public actor XRayOTelSpanExporter: OTelSpanExporter {
    private let configuration: XRayOTelExporterConfiguration
    private let client: any HTTPClient
    private let logger: Logger
    private let signer: AWSSigner
    private let serializer: TraceSerializer
    private var shutdowned = false

    init(
        configuration: XRayOTelExporterConfiguration,
        client: any HTTPClient,
        logger: Logger,
        signer: AWSSigner = DefaultAWSSigner(),
        serializer: TraceSerializer = DefaultTraceSerializer()
    ) {
        self.configuration = configuration
        self.client = client
        self.logger = logger
        self.signer = signer
        self.serializer = serializer
    }

    // Convenience initializer for backward compatibility
    public init(
        awsAccessKey: String,
        awsSecretAccessKey: String,
        awsSessionToken: String? = nil,
        region: String,
        client: any HTTPClient,
        customURL: URL? = nil,
        logger: Logger
    ) {
        let config = XRayOTelExporterConfiguration(
            awsAccessKey: awsAccessKey,
            awsSecretAccessKey: awsSecretAccessKey,
            awsSessionToken: awsSessionToken,
            region: region,
            customURL: customURL
        )
        self.init(
            configuration: config,
            client: client,
            logger: logger
        )
        
        logger.notice("[X-Ray] Exporter initialized", metadata: [
            "region": "\(region)",
            "url": "\(config.url)"
        ])
    }

    public func export(_ batch: some Collection<OTelFinishedSpan> & Sendable) async throws {
        logger.notice("[X-Ray] Export started")
        guard !shutdowned else {
            logger.error("Attempted to export batch while already being shut down.")
            throw OTelSpanExporterAlreadyShutDownError()
        }

        guard !batch.isEmpty else {
            logger.notice("[X-Ray] Empty batch, skipping export")
            return
        }

        logger.notice("[X-Ray] Exporting batch of \(batch.count) spans")

        // バッチを分割して処理
        let spans = Array(batch)
        for chunk in spans.chunked(into: configuration.maxBatchSize) {
            try await exportChunk(chunk)
        }
    }

    private func exportChunk(_ chunk: [OTelFinishedSpan]) async throws {
        logger.notice("[X-Ray] Processing chunk of \(chunk.count) spans")
        
        // Log trace IDs being exported
        for span in chunk {
            logger.notice("[X-Ray] Exporting span with trace ID: \(span.spanContext.traceID)")
        }
        
        let traces = try buildTracesData(from: chunk)
        let payload = try serializer.serialize(traces)
        logger.notice("[X-Ray] Serialized payload: \(payload.count) bytes")

        do {
            let request = try await createSignedRequest(payload: payload)
            logger.notice("[X-Ray] Request signed with AWS SigV4")
            let response = try await sendRequest(request)
            try validateResponse(response, spanCount: chunk.count)
        } catch {
            logger.error("[X-Ray] Failed to export spans: \(error)")
            throw error
        }
    }

    // Separated methods for better testability

    func buildTracesData(from spans: [OTelFinishedSpan]) throws
        -> Opentelemetry_Proto_Trace_V1_TracesData
    {
        guard let firstSpanResource = spans.first?.resource else {
            throw XRayOTelExporterError.emptyBatch
        }

        return Opentelemetry_Proto_Trace_V1_TracesData.with { request in
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
                            scopeSpans.spans = spans.map(convertOTelFinishedSpanToProto(span:))
                        }
                    ]
                }
            ]
        }
    }

    private func createSignedRequest(payload: Data) async throws -> HTTPRequest {
        guard let host = configuration.url.host(percentEncoded: true) else {
            throw XRayOTelExporterError.invalidXRayURL(configuration.url)
        }

        let builder = HTTPRequestBuilder()
            .withMethod(.post)
            .withProtocol(configuration.url.scheme == "http" ? .http : .https)
            .withHost(host)
            .withPath(configuration.url.path)
            .withHeader(name: "Content-Type", value: "application/x-protobuf")
            .withHeader(name: "Accept", value: "application/x-protobuf")
            .withHeader(name: "User-Agent", value: "swift-otel/1.0")
            .withHeader(name: "X-Amzn-Xray-Format", value: "otlp")
            .withBody(.data(payload))

        let signingProperties = createSigningProperties()

        let signedBuilder = try await signer.signRequest(
            requestBuilder: builder,
            identity: configuration.identity,
            signingProperties: signingProperties
        )

        return signedBuilder.build()
    }

    private func createSigningProperties() -> Smithy.Attributes {
        var props = Smithy.Attributes()
        props.set(key: SigningPropertyKeys.signingName, value: "xray")
        props.set(key: SigningPropertyKeys.signingRegion, value: configuration.region)
        props.set(key: SigningPropertyKeys.signingAlgorithm, value: SigningAlgorithm.sigv4)
        props.set(key: SigningPropertyKeys.bidirectionalStreaming, value: false)
        props.set(key: SigningPropertyKeys.unsignedBody, value: false)
        return props
    }

    private func sendRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Log detailed request information
        logger.notice("[X-Ray] Sending request", metadata: [
            "url": "\(configuration.url)",
            "method": "\(request.method)",
            "path": "\(request.path)",
            "headers": "\(request.headers)"
        ])
        
        // Log request body for debugging
        switch request.body {
        case .data(let bodyData):
            if let bodyData = bodyData {
                logger.notice("[X-Ray] Request body size: \(bodyData.count) bytes")
                // Log first 200 bytes of protobuf in hex for debugging
                let hexString = bodyData.prefix(200).map { String(format: "%02x", $0) }.joined(separator: " ")
                logger.notice("[X-Ray] Request body (first 200 bytes in hex): \(hexString)")
            } else {
                logger.notice("[X-Ray] Request body is nil")
            }
        case .stream:
            logger.notice("[X-Ray] Request body is a stream")
        case .noStream:
            logger.notice("[X-Ray] Request has no body")
        }
        
        do {
            // Send request directly without timeout wrapper to avoid potential issues
            let response = try await client.send(request: request)
            
            logger.notice("[X-Ray] Received response", metadata: [
                "status": "\(response.statusCode.rawValue)",
                "headers": "\(response.headers)"
            ])
            
            // Log error response body for debugging
            if response.statusCode.rawValue >= 400 {
                // Read body stream if available
                do {
                    if let data = try await response.body.readData() {
                        let bodyString = String(data: data, encoding: .utf8) ?? "Unable to decode body"
                        logger.error("[X-Ray] Error response body: \(bodyString)")
                        
                        // Also log response headers for error cases
                        logger.error("[X-Ray] Error response headers: \(response.headers)")
                    }
                } catch {
                    logger.error("[X-Ray] Failed to read error response body: \(error)")
                }
            }
            
            return response
        } catch {
            logger.error("[X-Ray] Failed to send request: \(error)")
            throw XRayOTelExporterError.networkError(error)
        }
    }

    private func validateResponse(_ response: HTTPResponse, spanCount: Int) throws {
        let status = response.statusCode.rawValue

        logger.debug("Received response with status code: \(status)")

        guard (200..<300).contains(status) else {
            logger.error("X-Ray OTLP endpoint returned error: \(status)")
            throw XRayOTelExporterError.httpError(statusCode: status, response: response)
        }

        logger.notice("[X-Ray] Successfully exported \(spanCount) spans")
    }

    public func forceFlush() async throws {
        logger.notice("[X-Ray] Force flush called - no pending spans to export (SimpleSpanProcessor exports immediately)")
    }

    public func shutdown() async {
        logger.notice("Shutting down X-Ray OTLP exporter")
        shutdowned = true
    }
}

// MARK: - Error Types

enum XRayOTelExporterError: Error, Sendable, Equatable {
    case invalidXRayURL(URL)
    case httpError(statusCode: Int, response: HTTPResponse)
    case networkError(Error)
    case serializationError(Error)
    case signingError(Error)
    case emptyBatch
    case maxRetriesExceeded

    static func == (lhs: XRayOTelExporterError, rhs: XRayOTelExporterError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidXRayURL(let url1), .invalidXRayURL(let url2)):
            return url1 == url2
        case (.httpError(let code1, _), .httpError(let code2, _)):
            return code1 == code2
        case (.emptyBatch, .emptyBatch), (.maxRetriesExceeded, .maxRetriesExceeded):
            return true
        default:
            return false
        }
    }
}

// MARK: - Helper Extensions

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Conversion Functions (remain the same as before)

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
        return nil
    }

    return anyValue
}

func convertOTelFinishedSpanToProto(span: OTelFinishedSpan) -> Opentelemetry_Proto_Trace_V1_Span {
    var protoSpan = Opentelemetry_Proto_Trace_V1_Span()

    // Trace ID (16 bytes)
    let traceIDData = span.spanContext.traceID.bytes.withUnsafeBytes { bytes in
        Data(bytes)
    }
    protoSpan.traceID = traceIDData
    
    // Debug: Log trace ID in hex format
    let traceIDHex = traceIDData.map { String(format: "%02x", $0) }.joined()
    print("[X-Ray Debug] Trace ID (hex): \(traceIDHex)")

    // Span ID (8 bytes)
    let spanIDData = span.spanContext.spanID.bytes.withUnsafeBytes { bytes in
        Data(bytes)
    }
    protoSpan.spanID = spanIDData
    
    // Debug: Log span ID in hex format
    let spanIDHex = spanIDData.map { String(format: "%02x", $0) }.joined()
    print("[X-Ray Debug] Span ID (hex): \(spanIDHex)")

    // Parent Span ID (8 bytes, optional)
    if let parentSpanID = span.spanContext.parentSpanID {
        protoSpan.parentSpanID = parentSpanID.bytes.withUnsafeBytes { bytes in
            Data(bytes)
        }
    }

    // Trace State
    protoSpan.traceState = convertTraceState(span.spanContext.traceState)

    // Flags
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
func convertSpanKind(_ kind: Tracing.SpanKind) -> Opentelemetry_Proto_Trace_V1_Span.SpanKind {
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
func convertStatus(_ status: SpanStatus) -> Opentelemetry_Proto_Trace_V1_Status {
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
