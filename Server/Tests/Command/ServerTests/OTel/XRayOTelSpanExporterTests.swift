import Foundation
import Logging
import OTel
import Smithy
import SmithyHTTPAPI
import SmithyIdentity
import SwiftProtobuf
import Synchronization
import Testing
import Tracing
import W3CTraceContext

@testable import CommandServer

actor MockHTTPClient: HTTPClient, @unchecked Sendable {
    var sentRequests: [HTTPRequest] = []
    var responseToReturn: HTTPResponse?
    var errorToThrow: Error?

    func send(request: HTTPRequest) async throws -> HTTPResponse {
        sentRequests.append(request)

        if let error = errorToThrow {
            throw error
        }

        return responseToReturn ?? .init(body: .empty, statusCode: .ok)
    }
}

struct MockAWSSigner: AWSSigner {
    var errorToThrow: Error?
    var signedHeaders: [String: String] = ["Authorization": "AWS4-HMAC-SHA256 Credential=..."]

    func signRequest(
        requestBuilder: HTTPRequestBuilder,
        identity: AWSCredentialIdentity,
        signingProperties: Smithy.Attributes
    ) async throws -> HTTPRequestBuilder {
        if let error = errorToThrow {
            throw error
        }

        // Add mock authorization header
        signedHeaders.forEach { key, value in
            requestBuilder.withHeader(name: key, value: value)
        }

        return requestBuilder
    }
}

final class MockTraceSerializer: TraceSerializer {
    let errorToThrow: Mutex<Error?> = .init(nil)
    let dataToReturn: Data = Data("mock-serialized-data".utf8)
    let capturedTraces: Mutex<[Opentelemetry_Proto_Trace_V1_TracesData]> = .init([])

    func serialize(_ traces: Opentelemetry_Proto_Trace_V1_TracesData) throws -> Data {
        capturedTraces.withLock {
            $0.append(traces)
        }

        try errorToThrow.withLock { error in
            if let error {
                throw error
            }
        }

        return dataToReturn
    }
}

// MARK: - Test Helpers

func createMockSpan(
    traceID: TraceID = TraceID.random(),
    spanID: SpanID = SpanID.random(),
    operationName: String = "test-operation",
    kind: SpanKind = .internal,
    attributes: SpanAttributes = [:]
) -> OTelFinishedSpan {
    let spanContext = OTelSpanContext(
        traceID: traceID,
        spanID: spanID,
        parentSpanID: nil,
        traceFlags: TraceFlags(sampled: true),
        traceState: TraceState(),
        isRemote: false
    )

    let resource = OTelResource(attributes: [
        "service.name": .string("test-service"),
        "service.version": .string("1.0.0"),
    ])

    return OTelFinishedSpan(
        spanContext: spanContext,
        resource: resource,
        instrumentationScopeInfo: InstrumentationScopeInfo(name: "test-scope"),
        operationName: operationName,
        kind: kind,
        status: nil,
        startTimeNanosecondsSinceEpoch: 1_000_000_000,
        endTimeNanosecondsSinceEpoch: 2_000_000_000,
        hasRemoteParent: false,
        attributes: attributes,
        events: [],
        links: []
    )
}

func createTestConfiguration() -> XRayOTelExporterConfiguration {
    XRayOTelExporterConfiguration(
        awsAccessKey: "test-access-key",
        awsSecretAccessKey: "test-secret-key",
        awsSessionToken: "test-session-token",
        region: "us-east-1",
        customURL: nil,
        maxBatchSize: 2,
        timeoutSeconds: 5.0
    )
}

// MARK: - Tests

struct XRayOTelSpanExporterTests {

    @Test("Successful export of spans")
    func testSuccessfulExport() async throws {
        // Arrange
        let mockClient = MockHTTPClient()
        mockClient.responseToReturn = HTTPResponse(
            statusCode: .ok,
            headers: [:],
            body: HTTPBody.data(Data())
        )

        let logger = Logger(label: "test")
        let config = createTestConfiguration()
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: mockClient,
            logger: logger,
            signer: MockAWSSigner()
        )

        let spans = [createMockSpan()]

        // Act
        try await exporter.export(spans)

        // Assert
        #expect(mockClient.sentRequests.count == 1)

        let request = mockClient.sentRequests[0]
        #expect(request.method == .post)
        #expect(request.headers["Content-Type"] == ["application/x-protobuf"])
        #expect(request.headers["Authorization"] != nil)
    }

    @Test("Export with empty batch")
    func testExportEmptyBatch() async throws {
        // Arrange
        let mockClient = MockHTTPClient()
        let logger = Logger(label: "test")
        let config = createTestConfiguration()
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: mockClient,
            logger: logger
        )

        let emptyBatch: [OTelFinishedSpan] = []

        // Act
        try await exporter.export(emptyBatch)

        // Assert
        #expect(mockClient.sentRequests.isEmpty)
    }

    @Test("Batch chunking with large batch")
    func testBatchChunking() async throws {
        // Arrange
        let mockClient = MockHTTPClient()
        mockClient.responseToReturn = HTTPResponse(
            statusCode: .ok,
            headers: [:],
            body: HTTPBody.data(Data())
        )

        let logger = Logger(label: "test")
        let config = createTestConfiguration()  // maxBatchSize = 2
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: mockClient,
            logger: logger,
            signer: MockAWSSigner()
        )

        // Create 5 spans (should result in 3 chunks: 2, 2, 1)
        let spans = (0..<5).map { _ in createMockSpan() }

        // Act
        try await exporter.export(spans)

        // Assert
        #expect(mockClient.sentRequests.count == 3)
    }

    @Test("HTTP error handling")
    func testHTTPErrorHandling() async throws {
        // Arrange
        let mockClient = MockHTTPClient()
        mockClient.responseToReturn = HTTPResponse(
            statusCode: .internalServerError,
            headers: [:],
            body: HTTPBody.data(Data("Server error".utf8))
        )

        let logger = Logger(label: "test")
        let config = createTestConfiguration()
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: mockClient,
            logger: logger,
            signer: MockAWSSigner()
        )

        let spans = [createMockSpan()]

        // Act & Assert
        await #expect(
            throws: XRayOTelExporterError.httpError(
                statusCode: 500, response: mockClient.responseToReturn!)
        ) {
            try await exporter.export(spans)
        }
    }

    @Test("Export after shutdown")
    func testExportAfterShutdown() async throws {
        // Arrange
        let mockClient = MockHTTPClient()
        let logger = Logger(label: "test")
        let config = createTestConfiguration()
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: mockClient,
            logger: logger
        )

        let spans = [createMockSpan()]

        // Shutdown the exporter
        await exporter.shutdown()

        // Act & Assert
        await #expect(throws: OTelSpanExporterAlreadyShutDownError.self) {
            try await exporter.export(spans)
        }
    }

    @Test("URL generation with custom URL")
    func testURLGenerationWithCustomURL() {
        // Arrange
        let customURL = URL(string: "https://custom-xray.example.com/traces")!
        let config = XRayOTelExporterConfiguration(
            awsAccessKey: "key",
            awsSecretAccessKey: "secret",
            region: "us-east-1",
            customURL: customURL
        )

        // Assert
        #expect(config.url == customURL)
    }

    @Test("URL generation with default URL")
    func testURLGenerationWithDefaultURL() {
        // Arrange
        let config = XRayOTelExporterConfiguration(
            awsAccessKey: "key",
            awsSecretAccessKey: "secret",
            region: "ap-northeast-1",
            customURL: nil
        )

        // Assert
        #expect(config.url.absoluteString == "https://xray.ap-northeast-1.amazonaws.com/v1/traces")
    }

    @Test("Build traces data from spans")
    func testBuildTracesData() async throws {
        // Arrange
        let logger = Logger(label: "test")
        let config = createTestConfiguration()
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: MockHTTPClient(),
            logger: logger
        )

        let spans = [
            createMockSpan(
                operationName: "operation-1",
                attributes: ["key1": .string("value1")]
            ),
            createMockSpan(
                operationName: "operation-2",
                attributes: ["key2": .int64(42)]
            ),
        ]

        // Act
        let tracesData = try await exporter.buildTracesData(from: spans)

        // Assert
        #expect(tracesData.resourceSpans.count == 1)
        #expect(tracesData.resourceSpans[0].scopeSpans.count == 1)
        #expect(tracesData.resourceSpans[0].scopeSpans[0].spans.count == 2)

        let protoSpans = tracesData.resourceSpans[0].scopeSpans[0].spans
        #expect(protoSpans[0].name == "operation-1")
        #expect(protoSpans[1].name == "operation-2")
    }

    @Test("Network error handling")
    func testNetworkErrorHandling() async throws {
        // Arrange
        struct NetworkError: Error {}

        let mockClient = MockHTTPClient()
        mockClient.errorToThrow = NetworkError()

        let logger = Logger(label: "test")
        let config = createTestConfiguration()
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: mockClient,
            logger: logger,
            signer: MockAWSSigner()
        )

        let spans = [createMockSpan()]

        // Act & Assert
        await #expect(throws: Error.self) {
            try await exporter.export(spans)
        }
    }

    @Test("Signing error handling")
    func testSigningErrorHandling() async throws {
        // Arrange
        struct SigningError: Error {}

        let mockClient = MockHTTPClient()
        let mockSigner = MockAWSSigner()
        mockSigner.errorToThrow = SigningError()

        let logger = Logger(label: "test")
        let config = createTestConfiguration()
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: mockClient,
            logger: logger,
            signer: mockSigner
        )

        let spans = [createMockSpan()]

        // Act & Assert
        await #expect(throws: SigningError.self) {
            try await exporter.export(spans)
        }
    }

    @Test("Force flush operation")
    func testForceFlush() async throws {
        // Arrange
        let logger = Logger(label: "test")
        let config = createTestConfiguration()
        let exporter = XRayOTelSpanExporter(
            configuration: config,
            client: MockHTTPClient(),
            logger: logger
        )

        // Act & Assert (should not throw)
        try await exporter.forceFlush()
    }
}

// MARK: - Conversion Function Tests

struct ConversionFunctionTests {

    @Test("Convert span attributes")
    func testConvertSpanAttributes() {
        // Test various attribute types
        let testCases: [(SpanAttribute, String)] = [
            (.int32(42), "42"),
            (.int64(9999), "9999"),
            (.double(3.14), "3.14"),
            (.bool(true), "true"),
            (.string("hello"), "hello"),
            (.stringConvertible(URL(string: "https://example.com")!), "https://example.com"),
        ]

        for (attribute, expectedString) in testCases {
            let anyValue = convertAttribute(attribute: attribute)
            #expect(anyValue != nil)

            switch attribute {
            case .int32, .int64:
                #expect(anyValue?.intValue != 0)
            case .double:
                #expect(anyValue?.doubleValue != 0)
            case .bool:
                #expect(anyValue?.boolValue == true)
            case .string, .stringConvertible:
                #expect(anyValue?.stringValue == expectedString)
            default:
                break
            }
        }
    }

    @Test("Convert array attributes")
    func testConvertArrayAttributes() {
        let intArrayAttr = SpanAttribute.int32Array([1, 2, 3])
        let anyValue = convertAttribute(attribute: intArrayAttr)

        #expect(anyValue != nil)
        #expect(anyValue?.arrayValue.values.count == 3)
        #expect(anyValue?.arrayValue.values[0].intValue == 1)
        #expect(anyValue?.arrayValue.values[1].intValue == 2)
        #expect(anyValue?.arrayValue.values[2].intValue == 3)
    }

    @Test("Convert span kind")
    func testConvertSpanKind() {
        let testCases: [(Tracing.SpanKind, Opentelemetry_Proto_Trace_V1_Span.SpanKind)] = [
            (.internal, .internal),
            (.server, .server),
            (.client, .client),
            (.producer, .producer),
            (.consumer, .consumer),
        ]

        for (input, expected) in testCases {
            let result = convertSpanKind(input)
            #expect(result == expected)
        }
    }

    @Test("Convert span status")
    func testConvertSpanStatus() {
        // Test OK status
        let okStatus = SpanStatus(code: .ok, message: nil)
        let protoOkStatus = convertStatus(okStatus)
        #expect(protoOkStatus.code == .ok)
        #expect(protoOkStatus.message.isEmpty)

        // Test Error status with message
        let errorStatus = SpanStatus(code: .error, message: "Something went wrong")
        let protoErrorStatus = convertStatus(errorStatus)
        #expect(protoErrorStatus.code == .error)
        #expect(protoErrorStatus.message == "Something went wrong")
    }

    @Test("Array chunking")
    func testArrayChunking() {
        let array = [1, 2, 3, 4, 5, 6, 7]
        let chunks = array.chunked(into: 3)

        #expect(chunks.count == 3)
        #expect(chunks[0] == [1, 2, 3])
        #expect(chunks[1] == [4, 5, 6])
        #expect(chunks[2] == [7])
    }
}
