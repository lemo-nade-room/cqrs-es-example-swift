import ServiceContextModule
import Tracing
import Vapor

/// Middleware that integrates swift-distributed-tracing with Vapor
struct DistributedTracingMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response
    {
        let method = request.method.rawValue
        let path = request.url.path
        let operationName = "\(method) \(path)"

        // Extract trace context from headers if available
        var serviceContext = ServiceContext.topLevel

        // Check for X-Ray trace header
        let headers = request.headers.reduce(into: [String: String]()) { result, header in
            result[header.name] = header.value
        }

        if let xRayContext = XRayPropagator.extractTraceContext(from: headers) {
            request.logger.debug(
                "🔗 X-Ray trace: \(xRayContext.traceId.hexString.suffix(8))...\(xRayContext.spanId.hexString.suffix(8))"
            )

            // Store the parent context information in ServiceContext
            // Since we can't directly create a parent span context with swift-distributed-tracing,
            // we'll need to pass this information through the tracer implementation
            serviceContext[XRayTraceContextKey.self] = xRayContext
        }

        // Use withSpan to automatically manage span lifecycle
        return try await withSpan(
            operationName,
            context: serviceContext,
            ofKind: .server
        ) { span in
            // Set span attributes
            span.updateAttributes { attributes in
                attributes["http.method"] = method
                attributes["http.target"] = path
                attributes["http.scheme"] = request.url.scheme ?? "http"
                if let host = request.headers.first(name: .host) {
                    attributes["http.host"] = host
                }
                if let userAgent = request.headers.first(name: .userAgent) {
                    attributes["http.user_agent"] = userAgent
                }
                if let peerAddress = request.peerAddress?.ipAddress {
                    attributes["net.peer.ip"] = peerAddress
                }
            }

            do {
                let response = try await next.respond(to: request)

                // Set response status code
                span.updateAttributes { attributes in
                    attributes["http.status_code"] = Int(response.status.code)
                }

                if response.status.code >= 400 {
                    span.setStatus(
                        SpanStatus(code: .error, message: "HTTP \(response.status.code)"))
                    request.logger.debug("❌ Request failed: \(response.status)")
                } else {
                    span.setStatus(SpanStatus(code: .ok))
                }

                return response
            } catch {
                request.logger.error("❌ Exception: \(error)")

                // Record the error on the span
                span.recordError(error)
                span.setStatus(SpanStatus(code: .error, message: error.localizedDescription))

                throw error
            }
        }
    }
}

// MARK: - ServiceContext Keys
enum XRayTraceContextKey: ServiceContextKey {
    typealias Value = XRayContext
    static let defaultValue: XRayContext? = nil
}

extension ServiceContext {
    /// Access X-Ray trace context if available
    var xRayTraceContext: XRayContext? {
        self[XRayTraceContextKey.self]
    }
}
