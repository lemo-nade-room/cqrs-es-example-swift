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

        // エラーやトレース伝播のために最小限のログのみ出力
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

        if let xRayContext = XRayPropagator.extractTraceContext(from: headers) {
            request.logger.debug(
                "🔗 X-Ray trace: \(xRayContext.traceId.hexString.suffix(8))...\(xRayContext.spanId.hexString.suffix(8))"
            )

            let spanContext = SpanContext.createFromRemoteParent(
                traceId: xRayContext.traceId,
                spanId: xRayContext.spanId,
                traceFlags: TraceFlags(fromByte: 1),  // Sampled
                traceState: TraceState()
            )
            spanBuilder.setParent(spanContext)
        }

        let span = spanBuilder.startSpan()

        defer {
            span.end()
        }

        do {
            let response = try await next.respond(to: request)
            span.setAttribute(key: "http.status_code", value: Int(response.status.code))

            if response.status.code >= 400 {
                span.status = Status.error(description: "HTTP \(response.status.code)")
                request.logger.debug("❌ Request failed: \(response.status)")
            } else {
                span.status = Status.ok
            }

            return response
        } catch {
            request.logger.error("❌ Exception: \(error)")

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
