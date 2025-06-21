import Vapor
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk

final class TracerWrapper: @unchecked Sendable {
    let tracer: any Tracer
    
    init(tracer: any Tracer) {
        self.tracer = tracer
    }
}

struct OpenTelemetryTracingMiddleware: AsyncMiddleware {
    private let tracerWrapper: TracerWrapper
    
    init(tracer: any Tracer) {
        self.tracerWrapper = TracerWrapper(tracer: tracer)
    }
    
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let method = request.method.rawValue
        let path = request.url.path
        let spanName = "\(method) \(path)"
        
        let span = tracerWrapper.tracer.spanBuilder(spanName: spanName)
            .setSpanKind(spanKind: .server)
            .setAttribute(key: "http.method", value: method)
            .setAttribute(key: "http.target", value: path)
            .setAttribute(key: "http.scheme", value: request.url.scheme ?? "http")
            .setAttribute(key: "http.host", value: request.headers.first(name: .host) ?? "unknown")
            .setAttribute(key: "http.user_agent", value: request.headers.first(name: .userAgent) ?? "")
            .setAttribute(key: "net.peer.ip", value: request.peerAddress?.ipAddress ?? "")
            .startSpan()
        
        defer {
            span.end()
        }
        
        do {
            let response = try await next.respond(to: request)
            
            span.setAttribute(key: "http.status_code", value: Int(response.status.code))
            
            if response.status.code >= 400 {
                span.status = Status.error(description: "HTTP \(response.status.code)")
            } else {
                span.status = Status.ok
            }
            
            return response
        } catch {
            span.addEvent(name: "exception", attributes: [
                "exception.type": AttributeValue.string(String(describing: type(of: error))),
                "exception.message": AttributeValue.string(error.localizedDescription)
            ])
            span.status = Status.error(description: error.localizedDescription)
            throw error
        }
    }
}