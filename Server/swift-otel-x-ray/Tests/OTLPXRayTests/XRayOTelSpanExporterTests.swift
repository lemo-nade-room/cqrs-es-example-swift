import Foundation
import Logging
import OTel
import Smithy
import SmithyHTTPAPI
import Testing
import Tracing

@testable import OTLPXRay

@Suite struct XRayOTelSpanExporterTests {
    @Test("X-Ray OTLP exporterを初期化できる")
    func testInitialization() async throws {
        let exporter = XRayOTelSpanExporter(
            awsAccessKey: "test-access-key",
            awsSecretAccessKey: "test-secret-key",
            awsSessionToken: "test-session-token",
            region: "ap-northeast-1",
            client: TestHTTPClient(),
            customURL: nil,
            logger: Logger(label: "test")
        )
        
        // 初期化が成功していることを確認
        // exporterは非オプショナルなので、初期化自体が成功したことを確認
        _ = exporter
    }
    
    @Test("カスタムURLを使用できる")
    func testCustomURLConfiguration() async throws {
        let customURL = URL(string: "https://custom.xray.endpoint.com/v1/traces")!
        let config = XRayOTelExporterConfiguration(
            awsAccessKey: "test-access-key",
            awsSecretAccessKey: "test-secret-key",
            awsSessionToken: nil,
            region: "us-west-2",
            customURL: customURL
        )
        
        #expect(config.url == customURL)
    }
    
    @Test("デフォルトURLが正しく構築される")
    func testDefaultURLConfiguration() async throws {
        let config = XRayOTelExporterConfiguration(
            awsAccessKey: "test-access-key",
            awsSecretAccessKey: "test-secret-key",
            region: "ap-northeast-1"
        )
        
        #expect(config.url == URL(string: "https://xray.ap-northeast-1.amazonaws.com/v1/traces")!)
    }
}

// Simple test HTTP client
final class TestHTTPClient: HTTPClient {
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(
            headers: .init(httpHeaders: []),
            body: .data(nil),
            statusCode: .ok,
            reason: nil
        )
    }
}