@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk
import Vapor

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

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response
    {
        let method = request.method.rawValue
        let path = request.url.path
        let spanName = "\(method) \(path)"
        
        request.logger.debug("[DEBUG] OpenTelemetryTracingMiddleware processing request")
        request.logger.debug("[DEBUG]   Method: \(method)")
        request.logger.debug("[DEBUG]   Path: \(path)")
        request.logger.debug("[DEBUG]   Span name: \(spanName)")

        let spanBuilder = tracerWrapper.tracer.spanBuilder(spanName: spanName)
            .setSpanKind(spanKind: .server)
            .setAttribute(key: "http.method", value: method)
            .setAttribute(key: "http.target", value: path)
            .setAttribute(key: "http.scheme", value: request.url.scheme ?? "http")
            .setAttribute(key: "http.host", value: request.headers.first(name: .host) ?? "unknown")
            .setAttribute(
                key: "http.user_agent", value: request.headers.first(name: .userAgent) ?? ""
            )
            .setAttribute(key: "net.peer.ip", value: request.peerAddress?.ipAddress ?? "")

        // Extract X-Ray trace context if available
        let headers = request.headers.reduce(into: [String: String]()) { result, header in
            result[header.name] = header.value
        }
        
        request.logger.debug("[DEBUG] Checking for X-Ray trace context")
        if let traceHeader = headers["x-amzn-trace-id"] {
            request.logger.debug("[DEBUG]   X-Ray trace header found: \(traceHeader)")
        }

        if let xRayContext = XRayPropagator.extractTraceContext(from: headers) {
            request.logger.debug("[DEBUG]   Extracted trace context:")
            request.logger.debug("[DEBUG]     TraceId: \(xRayContext.traceId.hexString)")
            request.logger.debug("[DEBUG]     SpanId: \(xRayContext.spanId.hexString)")
            
            // Create a remote span context with the extracted trace ID and span ID
            let spanContext = SpanContext.createFromRemoteParent(
                traceId: xRayContext.traceId,
                spanId: xRayContext.spanId,
                traceFlags: TraceFlags(fromByte: 1),  // Sampled
                traceState: TraceState()
            )

            spanBuilder.setParent(spanContext)
        } else {
            request.logger.debug("[DEBUG]   No X-Ray trace context found")
        }

        let span = spanBuilder.startSpan()
        request.logger.debug("[DEBUG] Span started: \(span.context.spanId.hexString)")

        defer {
            request.logger.debug("[DEBUG] Ending span: \(span.context.spanId.hexString)")
            span.end()
        }

        do {
            let response = try await next.respond(to: request)

            span.setAttribute(key: "http.status_code", value: Int(response.status.code))
            request.logger.debug("[DEBUG] Response status: \(response.status.code)")

            if response.status.code >= 400 {
                span.status = Status.error(description: "HTTP \(response.status.code)")
                request.logger.debug("[DEBUG] Span marked as error")
            } else {
                span.status = Status.ok
                request.logger.debug("[DEBUG] Span marked as ok")
            }

            return response
        } catch {
            span.addEvent(
                name: "exception",
                attributes: [
                    "exception.type": AttributeValue.string(String(describing: type(of: error))),
                    "exception.message": AttributeValue.string(error.localizedDescription),
                ])
            span.status = Status.error(description: error.localizedDescription)
            throw error
        }
    }
}
