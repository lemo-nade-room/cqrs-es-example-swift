import Testing

@testable import CommandServer
@testable import OpenTelemetryApi

@Suite("XRayPropagator Tests")
struct XRayPropagatorTests {

    @Test("Extract returns nil when header is absent")
    func extractReturnsNilWhenHeaderAbsent() {
        let headers = [String: String]()

        let actual = XRayPropagator.extractTraceContext(from: headers)

        #expect(actual == nil)
    }

    @Test("Extract parses valid X-Amzn-Trace-Id header")
    func extractParsesValidXAmznTraceId() throws {
        let headers = [
            "X-Amzn-Trace-Id":
                "Root=1-684cd338-55ea19fa5d8a7e683178aa1b;Parent=944a39c5ded7c2b1;Sampled=1;Lineage=1:7326f8b8:0"
        ]

        let context = try #require(XRayPropagator.extractTraceContext(from: headers))
        let traceId = context.traceId
        let spanId = context.spanId

        // Verify trace ID
        #expect(traceId.hexString == "684cd33855ea19fa5d8a7e683178aa1b")

        // Verify span ID
        #expect(spanId.hexString == "944a39c5ded7c2b1")
    }

    @Test("Extract parses lowercase header")
    func extractParsesLowercaseHeader() throws {
        let headers = [
            "x-amzn-trace-id":
                "Root=1-684cd338-55ea19fa5d8a7e683178aa1b;Parent=944a39c5ded7c2b1;Sampled=1"
        ]

        let context = try #require(XRayPropagator.extractTraceContext(from: headers))
        let traceId = context.traceId
        let spanId = context.spanId

        #expect(traceId.hexString == "684cd33855ea19fa5d8a7e683178aa1b")
        #expect(spanId.hexString == "944a39c5ded7c2b1")
    }

    @Test("Extract handles fields in different order")
    func extractHandlesFieldsInDifferentOrder() throws {
        let headers = [
            "X-Amzn-Trace-Id":
                "Parent=944a39c5ded7c2b1;Root=1-684cd338-55ea19fa5d8a7e683178aa1b;Sampled=0"
        ]

        let context = try #require(XRayPropagator.extractTraceContext(from: headers))
        let traceId = context.traceId
        let spanId = context.spanId

        #expect(traceId.hexString == "684cd33855ea19fa5d8a7e683178aa1b")
        #expect(spanId.hexString == "944a39c5ded7c2b1")
    }

    @Test("Extract handles extra spaces between fields")
    func extractHandlesExtraSpaces() throws {
        let headers = [
            "X-Amzn-Trace-Id":
                "Root=1-684cd338-55ea19fa5d8a7e683178aa1b; Parent=944a39c5ded7c2b1; Sampled=1"
        ]

        let context = try #require(XRayPropagator.extractTraceContext(from: headers))
        let traceId = context.traceId
        let spanId = context.spanId

        #expect(traceId.hexString == "684cd33855ea19fa5d8a7e683178aa1b")
        #expect(spanId.hexString == "944a39c5ded7c2b1")
    }

    @Test("Extract returns nil when Root field is missing")
    func extractReturnsNilWhenRootMissing() {
        let headers = [
            "X-Amzn-Trace-Id": "Parent=944a39c5ded7c2b1;Sampled=1"
        ]

        let actual = XRayPropagator.extractTraceContext(from: headers)

        #expect(actual == nil)
    }

    @Test("Extract returns nil when Parent field is missing")
    func extractReturnsNilWhenParentMissing() {
        let headers = [
            "X-Amzn-Trace-Id": "Root=1-684cd338-55ea19fa5d8a7e683178aa1b;Sampled=1"
        ]

        let actual = XRayPropagator.extractTraceContext(from: headers)

        #expect(actual == nil)
    }

    @Test("Extract returns nil when Root format is invalid")
    func extractReturnsNilWhenRootFormatInvalid() {
        let headers = [
            "X-Amzn-Trace-Id": "Root=invalid;Parent=944a39c5ded7c2b1;Sampled=1"
        ]

        let actual = XRayPropagator.extractTraceContext(from: headers)

        #expect(actual == nil)
    }

    @Test("Extract works with minimal valid header")
    func extractWorksWithMinimalValidHeader() throws {
        let headers = [
            "X-Amzn-Trace-Id": "Root=1-684cd338-55ea19fa5d8a7e683178aa1b;Parent=944a39c5ded7c2b1"
        ]

        let context = try #require(XRayPropagator.extractTraceContext(from: headers))
        let traceId = context.traceId
        let spanId = context.spanId

        #expect(traceId.hexString == "684cd33855ea19fa5d8a7e683178aa1b")
        #expect(spanId.hexString == "944a39c5ded7c2b1")
    }

    @Test(
        "Extract handles various X-Ray trace header formats",
        arguments: [
            (
                header:
                    "Root=1-5e1b4f2a-6b7c8d9e0f1a2b3c4d5e6f7a;Parent=1234567890abcdef;Sampled=1",
                expectedTraceId: "5e1b4f2a6b7c8d9e0f1a2b3c4d5e6f7a",
                expectedSpanId: "1234567890abcdef"
            ),
            (
                header:
                    "Root=1-00000000-000000000000000000000000;Parent=0000000000000000;Sampled=0",
                expectedTraceId: "00000000000000000000000000000000",
                expectedSpanId: "0000000000000000"
            ),
        ]
    )
    func extractHandlesVariousFormats(
        header: String, expectedTraceId: String, expectedSpanId: String
    ) throws {
        let headers = ["X-Amzn-Trace-Id": header]

        let context = try #require(XRayPropagator.extractTraceContext(from: headers))
        let traceId = context.traceId
        let spanId = context.spanId

        #expect(traceId.hexString == expectedTraceId)
        #expect(spanId.hexString == expectedSpanId)
    }
}
