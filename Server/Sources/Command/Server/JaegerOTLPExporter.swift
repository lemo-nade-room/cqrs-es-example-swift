import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
@preconcurrency import OpenTelemetrySdk

/// Simple Jaeger OTLP HTTP Exporter for local development
final class JaegerOTLPExporter: SpanExporter, @unchecked Sendable {
    private let endpoint: URL
    private let httpClient: HTTPClient
    private let resource: Resource
    
    init(endpoint: URL, resource: Resource? = nil, eventLoopGroup: any EventLoopGroup) async throws {
        // Ensure endpoint ends with /v1/traces
        if !endpoint.absoluteString.hasSuffix("/v1/traces") {
            self.endpoint = endpoint.appendingPathComponent("v1/traces")
        } else {
            self.endpoint = endpoint
        }
        
        self.resource = resource ?? Resource()
        
        // HTTP client configuration
        var configuration = HTTPClient.Configuration()
        configuration.timeout = .init(connect: .seconds(5), read: .seconds(30))
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup), configuration: configuration)
        
        print("🏛️ Initializing JaegerOTLPExporter | Endpoint: \(self.endpoint)")
    }
    
    deinit {
        try? httpClient.syncShutdown()
    }
    
    func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil) -> OpenTelemetrySdk.SpanExporterResultCode {
        print("📦 Exporting \(spans.count) spans to Jaeger")
        
        // Convert to Protobuf format
        do {
            let resourceSpans = Opentelemetry_Proto_Trace_V1_ResourceSpans.with {
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
            
            let exportRequest = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
                $0.resourceSpans = [resourceSpans]
            }
            
            let body = try exportRequest.serializedData()
            let spanCount = spans.count
            
            // Send asynchronously (fire-and-forget)
            Task.detached { [weak self] in
                guard let self = self else { return }
                
                do {
                    try await self.sendHTTPRequest(body: body)
                    print("✅ Exported \(spanCount) spans to Jaeger successfully")
                } catch {
                    print("❌ Jaeger export failed: \(error)")
                }
            }
        } catch {
            print("❌ Failed to serialize spans: \(error)")
            return .failure
        }
        
        return .success
    }
    
    private func sendHTTPRequest(body: Data) async throws {
        var request = HTTPClientRequest(url: endpoint.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-protobuf")
        request.headers.add(name: "Content-Length", value: String(body.count))
        request.body = .bytes(ByteBuffer(data: body))
        
        print("📡 Sending to: \(endpoint.absoluteString)")
        
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        print("✅ Jaeger API response: \(response.status.code)")
        
        if response.status.code >= 400 {
            throw ExportError.httpError(statusCode: Int(response.status.code))
        }
    }
    
    func flush(explicitTimeout: TimeInterval? = nil) -> OpenTelemetrySdk.SpanExporterResultCode {
        return .success
    }
    
    func shutdown(explicitTimeout: TimeInterval? = nil) {
        try? httpClient.syncShutdown()
    }
}

// Reuse ExportError from AWSXRayOTLPExporter
extension JaegerOTLPExporter {
    enum ExportError: Error {
        case httpError(statusCode: Int)
    }
}