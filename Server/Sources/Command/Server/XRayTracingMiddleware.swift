import Vapor
import Tracing
import Instrumentation
import W3CTraceContext
import OTel

/// Custom tracing middleware that ensures X-Ray trace IDs from HTTP headers are used
public final class XRayTracingMiddleware: AsyncMiddleware {
    public init() {
    }
    
    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Extract parent context from headers using X-Ray propagator
        var parentContext = request.serviceContext
        
        // Log the incoming headers for debugging
        if let xrayHeader = request.headers["x-amzn-trace-id"].first {
            request.logger.info("[XRayTracingMiddleware] Found X-Ray header: \(xrayHeader)")
        } else {
            request.logger.info("[XRayTracingMiddleware] No X-Ray header found in request")
        }
        
        // Use the InstrumentationSystem to extract context properly
        InstrumentationSystem.instrument.extract(request.headers, into: &parentContext, using: HTTPHeadersExtractor())
        
        // Log the extracted context
        if let spanContext = parentContext.spanContext {
            request.logger.info("[XRayTracingMiddleware] Successfully extracted span context")
            request.logger.info("[XRayTracingMiddleware] Trace ID: \(spanContext.traceID)")
            request.logger.info("[XRayTracingMiddleware] Span ID: \(spanContext.spanID)")
        } else {
            request.logger.warning("[XRayTracingMiddleware] No span context found after extraction")
        }
        
        return try await withSpan(
            request.route?.description ?? "vapor_route_undefined",
            context: parentContext,
            ofKind: .server
        ) { span in
            // Set the request.serviceContext for the duration of this middleware
            request.serviceContext = span.context
            defer {
                request.serviceContext = parentContext
            }
            
            // Log the actual trace ID being used
            if let spanContext = span.context.spanContext {
                request.logger.info("[XRayTracingMiddleware] Using trace ID: \(spanContext.traceID)")
            }
            
            // Set span attributes
            span.updateAttributes { attributes in
                // Required
                attributes["http.request.method"] = request.method.rawValue
                attributes["url.path"] = request.url.path
                attributes["url.scheme"] = request.url.scheme
                
                // Conditionally required
                if let route = request.route {
                    attributes["http.route"] = "/" + route.path.map { "\($0)" }.joined(separator: "/")
                }
                
                attributes["network.protocol.name"] = "http"
                switch request.application.http.server.configuration.address {
                    case let .hostname(address, port):
                        attributes["server.address"] = address
                        attributes["server.port"] = port
                    case let .unixDomainSocket(path):
                        attributes["server.address"] = path
                }
                attributes["url.query"] = request.url.query
                
                // Recommended
                attributes["client.address"] = request.peerAddress?.ipAddress
                attributes["network.peer.address"] = request.remoteAddress?.ipAddress
                attributes["network.peer.port"] = request.remoteAddress?.port
                attributes["network.protocol.version"] = "\(request.version.major).\(request.version.minor)"
                attributes["user_agent.original"] = request.headers[.userAgent].first
            }
            
            let response = try await next.respond(to: request)
            
            span.updateAttributes { attributes in
                attributes["http.response.status_code"] = Int(response.status.code)
            }
            
            if 500 <= response.status.code && response.status.code < 600 {
                span.setStatus(.init(code: .error))
            }
            
            return response
        }
    }
}

// HTTPHeadersExtractor for X-Ray propagator
private struct HTTPHeadersExtractor: Extractor {
    func extract(key name: String, from headers: HTTPHeaders) -> String? {
        let headerValue = headers[name]
        if headerValue.isEmpty {
            return nil
        } else {
            return headerValue.joined(separator: ";")
        }
    }
}