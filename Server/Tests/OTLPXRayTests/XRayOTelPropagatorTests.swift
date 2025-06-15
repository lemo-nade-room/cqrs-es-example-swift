import Instrumentation
import Logging
import OTel
import Testing

@testable import OTLPXRay

@Suite struct XRayOTelPropagatorTests {
    @Test("x-amzn-trace-idが存在しない場合は抽出できずコンテキストはnilとなる")
    func testExtractReturnsNilWhenHeaderAbsent() async throws {
        let headers = [String: String]()
        let sut = XRayOTelPropagator(logger: Logger(label: "test"))

        let actual = try sut.extractSpanContext(from: headers, using: DictionaryExtractor())

        #expect(actual == nil)
    }

    @Test("x-amzn-trace-idからSpanContextを抽出できる")
    func testExtractParsesValidXAmznTraceId() async throws {
        let headers = [
            "x-amzn-trace-id":
                "Root=1-684cd338-55ea19fa5d8a7e683178aa1b;Parent=944a39c5ded7c2b1;Sampled=1;Lineage=1:7326f8b8:0"
        ]
        let sut = XRayOTelPropagator(logger: Logger(label: "test"))

        let actual = try #require(
            try sut.extractSpanContext(from: headers, using: DictionaryExtractor()))

        #expect(
            actual
                == .remote(
                    traceContext: .init(
                        traceID: .init(
                            bytes: .init(
                                (
                                    0x68,
                                    0x4c,
                                    0xd3,
                                    0x38,
                                    0x55,
                                    0xea,
                                    0x19,
                                    0xfa,
                                    0x5d,
                                    0x8a,
                                    0x7e,
                                    0x68,
                                    0x31,
                                    0x78,
                                    0xaa,
                                    0x1b,
                                )
                            )
                        ),
                        spanID: .init(
                            bytes: .init(
                                (
                                    0x94,
                                    0x4a,
                                    0x39,
                                    0xc5,
                                    0xde,
                                    0xd7,
                                    0xc2,
                                    0xb1,
                                )
                            )
                        ),
                        flags: .sampled,
                        state: .init([])
                    )
                )
        )
    }

    @Test("x-amzn-trace-idにSpanContextの値をX-Ray形式で注入できる")
    func testInjectSerializesSpanContextToHeader() async throws {
        var headers = [String: String]()
        let spanContext: OTelSpanContext = .local(
            traceID: .init(
                bytes: .init(
                    (
                        0x01,
                        0x02,
                        0x03,
                        0x04,
                        0x05,
                        0x06,
                        0x07,
                        0x08,
                        0x09,
                        0x10,
                        0x11,
                        0x12,
                        0x13,
                        0x14,
                        0x15,
                        0x16,
                    )
                )
            ),
            spanID: .init(
                bytes: .init(
                    (
                        0x01,
                        0x02,
                        0x03,
                        0x04,
                        0x05,
                        0x06,
                        0x07,
                        0x08,
                    )
                )
            ),
            parentSpanID: .init(
                bytes: .init(
                    (
                        0x94,
                        0x4a,
                        0x39,
                        0xc5,
                        0xde,
                        0xd7,
                        0xc2,
                        0xb1,
                    )
                )
            ),
            traceFlags: .init(),
            traceState: .init()
        )
        let sut = XRayOTelPropagator(logger: Logger(label: "test"))

        sut.inject(spanContext, into: &headers, using: DictionaryInjector())

        #expect(
            headers == [
                "x-amzn-trace-id":
                    "Root=1-01020304-050607080910111213141516;Parent=0102030405060708;Sampled=0"
            ])
    }

    struct DictionaryExtractor: Extractor {
        func extract(key: String, from carrier: [String: String]) -> String? {
            carrier[key]
        }
    }

    struct DictionaryInjector: Injector {
        func inject(_ value: String, forKey key: String, into carrier: inout [String: String]) {
            carrier[key] = value
        }
    }
}