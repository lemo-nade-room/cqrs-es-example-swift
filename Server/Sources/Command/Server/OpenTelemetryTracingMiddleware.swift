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

        request.logger.debug("[DEBUG] ========== OpenTelemetryTracingMiddleware START ==========")
        request.logger.debug("[DEBUG] Request details:")
        request.logger.debug("[DEBUG]   Method: \(method)")
        request.logger.debug("[DEBUG]   Path: \(path)")
        request.logger.debug("[DEBUG]   Span name: \(spanName)")
        request.logger.debug("[DEBUG]   Scheme: \(request.url.scheme ?? "unknown")")
        request.logger.debug("[DEBUG]   Host: \(request.headers.first(name: .host) ?? "unknown")")
        request.logger.debug(
            "[DEBUG]   User-Agent: \(request.headers.first(name: .userAgent) ?? "none")")
        request.logger.debug("[DEBUG]   Peer IP: \(request.peerAddress?.ipAddress ?? "unknown")")

        request.logger.debug("[DEBUG] Building span with attributes")
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
        request.logger.debug("[DEBUG] Extracting headers for trace context")
        let headers = request.headers.reduce(into: [String: String]()) { result, header in
            result[header.name] = header.value
            request.logger.debug("[DEBUG]   Header: \(header.name) = \(header.value)")
        }

        request.logger.debug("[DEBUG] Checking for X-Ray trace context")
        if let traceHeader = headers["x-amzn-trace-id"] {
            request.logger.debug("[DEBUG] 🔍 X-Ray trace header found: \(traceHeader)")
        } else {
            request.logger.debug("[DEBUG] ⚠️ No x-amzn-trace-id header found")
        }

        request.logger.debug("[DEBUG] Calling XRayPropagator.extractTraceContext")
        if let xRayContext = XRayPropagator.extractTraceContext(from: headers) {
            request.logger.debug("[DEBUG] ✅ Extracted X-Ray trace context successfully:")
            request.logger.debug("[DEBUG]   TraceId: \(xRayContext.traceId.hexString)")
            request.logger.debug("[DEBUG]   SpanId: \(xRayContext.spanId.hexString)")

            // Create a remote span context with the extracted trace ID and span ID
            request.logger.debug("[DEBUG] Creating remote parent span context")
            let spanContext = SpanContext.createFromRemoteParent(
                traceId: xRayContext.traceId,
                spanId: xRayContext.spanId,
                traceFlags: TraceFlags(fromByte: 1),  // Sampled
                traceState: TraceState()
            )

            request.logger.debug("[DEBUG] Setting parent context on span builder")
            spanBuilder.setParent(spanContext)
            request.logger.debug("[DEBUG] ✅ Parent context set")
        } else {
            request.logger.debug("[DEBUG] ⚠️ No X-Ray trace context could be extracted")
        }

        request.logger.debug("[DEBUG] Starting span")
        let span = spanBuilder.startSpan()
        request.logger.debug("[DEBUG] ✅ Span started:")
        request.logger.debug("[DEBUG]   SpanId: \(span.context.spanId.hexString)")
        request.logger.debug("[DEBUG]   TraceId: \(span.context.traceId.hexString)")
        request.logger.debug("[DEBUG]   IsRecording: \(span.isRecording)")
        request.logger.debug("[DEBUG]   TraceFlags: \(span.context.traceFlags)")

        defer {
            request.logger.debug("[DEBUG] 🔚 Ending span: \(span.context.spanId.hexString)")
            span.end()
            request.logger.debug("[DEBUG] ✅ Span ended")
            request.logger.debug("[DEBUG] ========== OpenTelemetryTracingMiddleware END ==========")
        }

        do {
            request.logger.debug("[DEBUG] Calling next responder in chain")
            let response = try await next.respond(to: request)

            span.setAttribute(key: "http.status_code", value: Int(response.status.code))
            request.logger.debug("[DEBUG] Response received:")
            request.logger.debug("[DEBUG]   Status code: \(response.status.code)")
            request.logger.debug("[DEBUG]   Status: \(response.status)")

            if response.status.code >= 400 {
                span.status = Status.error(description: "HTTP \(response.status.code)")
                request.logger.debug(
                    "[DEBUG] ❌ Span marked as error (HTTP \(response.status.code))")
            } else {
                span.status = Status.ok
                request.logger.debug("[DEBUG] ✅ Span marked as ok")
            }

            request.logger.debug("[DEBUG] Returning response")
            return response
        } catch {
            request.logger.debug("[DEBUG] ❌ Error caught: \(error)")
            request.logger.debug("[DEBUG]   Error type: \(type(of: error))")
            request.logger.debug("[DEBUG]   Error description: \(error.localizedDescription)")

            span.addEvent(
                name: "exception",
                attributes: [
                    "exception.type": AttributeValue.string(String(describing: type(of: error))),
                    "exception.message": AttributeValue.string(error.localizedDescription),
                ])
            span.status = Status.error(description: error.localizedDescription)
            request.logger.debug("[DEBUG] ❌ Span marked as error with exception")
            throw error
        }
    }
}
