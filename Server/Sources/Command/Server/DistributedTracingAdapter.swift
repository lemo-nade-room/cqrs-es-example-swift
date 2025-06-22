import Foundation
import NIOCore
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk
import ServiceContextModule
import Tracing

/// Adapter that bridges OpenTelemetry with swift-distributed-tracing
struct OpenTelemetryDistributedTracer: Sendable {
    private let openTelemetryTracer: any OpenTelemetryApi.Tracer

    init(openTelemetryTracer: any OpenTelemetryApi.Tracer) {
        self.openTelemetryTracer = openTelemetryTracer
    }
}

// MARK: - Instrument Protocol Conformance
extension OpenTelemetryDistributedTracer: Instrumentation.Instrument {
    func extract<Carrier, Extract>(
        _ carrier: Carrier, into context: inout ServiceContext, using extractor: Extract
    )
    where Extract: Extractor, Extract.Carrier == Carrier {
        // X-Ray trace header extraction
        if let xRayHeader = extractor.extract(key: "X-Amzn-Trace-Id", from: carrier) {
            // Convert single header value to dictionary for XRayPropagator
            let headers = ["X-Amzn-Trace-Id": xRayHeader]
            if let xRayContext = XRayPropagator.extractTraceContext(from: headers) {
                context[XRayTraceContextKey.self] = xRayContext
            }
        }
    }

    func inject<Carrier, Inject>(
        _ context: ServiceContext, into carrier: inout Carrier, using injector: Inject
    )
    where Inject: Injector, Inject.Carrier == Carrier {
        // For now, we'll skip injection as X-Ray propagation is handled separately
        // In a full implementation, we would inject trace context into the carrier
    }
}

// MARK: - Tracer Protocol Conformance
extension OpenTelemetryDistributedTracer: Tracing.Tracer {
    func startSpan<Instant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: Tracing.SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> OpenTelemetryDistributedSpan where Instant: TracerInstant {
        // Convert swift-distributed-tracing SpanKind to OpenTelemetry SpanKind
        let otelKind: OpenTelemetryApi.SpanKind
        switch kind {
        case .server:
            otelKind = .server
        case .client:
            otelKind = .client
        case .producer:
            otelKind = .producer
        case .consumer:
            otelKind = .consumer
        case .internal:
            otelKind = .internal
        }

        // Build span
        let spanBuilder = openTelemetryTracer.spanBuilder(spanName: operationName)
            .setSpanKind(spanKind: otelKind)

        // Check if there's a parent span in the context
        let currentContext = context()
        if let parentSpan = currentContext.distributedTracingSpan {
            // Extract parent context if available
            if let parentOTelSpan = parentSpan as? OpenTelemetryDistributedSpan {
                spanBuilder.setParent(parentOTelSpan.openTelemetrySpan)
            }
        } else if let xRayContext = currentContext.xRayTraceContext {
            // Use X-Ray trace context if available
            let spanContext = SpanContext.createFromRemoteParent(
                traceId: xRayContext.traceId,
                spanId: xRayContext.spanId,
                traceFlags: TraceFlags(fromByte: xRayContext.sampled ? 1 : 0),
                traceState: TraceState()
            )
            spanBuilder.setParent(spanContext)
        }

        // Start the span
        let openTelemetrySpan = spanBuilder.startSpan()

        // Create the wrapper span
        let span = OpenTelemetryDistributedSpan(
            openTelemetrySpan: openTelemetrySpan,
            context: currentContext
        )

        return span
    }

    func activeSpan(identifiedBy context: ServiceContext) -> OpenTelemetryDistributedSpan? {
        // This is optional and we'll return nil for now
        nil
    }

    // MARK: - LegacyTracer Protocol Conformance
    @available(*, deprecated, message: "prefer withSpan")
    func startAnySpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: Tracing.SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> any Tracing.Span {
        // Delegate to the typed startSpan method
        return startSpan(
            operationName,
            context: context(),
            ofKind: kind,
            at: instant(),
            function: function,
            file: fileID,
            line: line
        )
    }

    @available(*, deprecated)
    func forceFlush() {
        // OpenTelemetry doesn't have a force flush on the tracer level
        // This would be handled at the span processor level
    }
}

// MARK: - Span Wrapper
actor OpenTelemetryDistributedSpan {
    nonisolated let openTelemetrySpan: any OpenTelemetryApi.Span
    nonisolated let context: ServiceContext

    init(openTelemetrySpan: any OpenTelemetryApi.Span, context: ServiceContext) {
        self.openTelemetrySpan = openTelemetrySpan
        self.context = context
    }
}


// MARK: - Span Protocol Conformance
extension OpenTelemetryDistributedSpan: Tracing.Span {
    nonisolated var operationName: String {
        get {
            // OpenTelemetry doesn't expose operation name getter
            ""
        }
        set {
            // OpenTelemetry doesn't support updating the span name after creation in the current API
            // We would need to store this separately if name updates are required
        }
    }

    nonisolated func setStatus(_ status: SpanStatus) {
        switch status.code {
        case .ok:
            openTelemetrySpan.status = OpenTelemetryApi.Status.ok
        case .error:
            openTelemetrySpan.status = OpenTelemetryApi.Status.error(
                description: status.message ?? "Error"
            )
        }
    }

    nonisolated func addEvent(_ event: SpanEvent) {
        let otelAttributes: [String: AttributeValue] = event.attributes._attributes.reduce(into: [:]
        ) { result, pair in
            if let otelAttribute = convertToOTelAttribute(pair.value) {
                result[pair.key] = otelAttribute
            }
        }

        openTelemetrySpan.addEvent(
            name: event.name,
            attributes: otelAttributes,
            timestamp: Date(
                timeIntervalSince1970: TimeInterval(event.nanosecondsSinceEpoch) / 1_000_000_000)
        )
    }

    nonisolated func recordError<Instant>(
        _ error: any Error,
        attributes: SpanAttributes,
        at instant: @autoclosure () -> Instant
    ) where Instant: TracerInstant {
        let otelAttributes: [String: AttributeValue] = attributes._attributes.reduce(into: [:]) {
            result, pair in
            if let otelAttribute = convertToOTelAttribute(pair.value) {
                result[pair.key] = otelAttribute
            }
        }

        var allAttributes = otelAttributes
        allAttributes["exception.type"] = AttributeValue.string(String(describing: type(of: error)))
        allAttributes["exception.message"] = AttributeValue.string(error.localizedDescription)

        openTelemetrySpan.addEvent(
            name: "exception",
            attributes: allAttributes,
            timestamp: Date(
                timeIntervalSince1970: TimeInterval(instant().nanosecondsSinceEpoch) / 1_000_000_000
            )
        )

        openTelemetrySpan.status = OpenTelemetryApi.Status.error(
            description: error.localizedDescription
        )
    }

    nonisolated var attributes: SpanAttributes {
        get {
            // OpenTelemetry doesn't expose attributes getter, return empty
            SpanAttributes()
        }
        set {
            // Set each attribute individually
            for (key, value) in newValue._attributes {
                if let otelAttribute = convertToOTelAttribute(value) {
                    openTelemetrySpan.setAttribute(key: key, value: otelAttribute)
                }
            }
        }
    }

    nonisolated var isRecording: Bool {
        openTelemetrySpan.isRecording
    }

    nonisolated func addLink(_ link: SpanLink) {
        // OpenTelemetry doesn't support adding links after span creation
        // This is a limitation we'll have to accept
    }

    nonisolated func end<Instant>(at instant: @autoclosure () -> Instant) where Instant: TracerInstant {
        let timestamp = Date(
            timeIntervalSince1970: TimeInterval(instant().nanosecondsSinceEpoch) / 1_000_000_000
        )
        openTelemetrySpan.end(time: timestamp)
    }
}

// MARK: - Attribute Conversion
private func convertToOTelAttribute(_ attribute: Tracing.SpanAttribute) -> AttributeValue? {
    switch attribute {
    case .int32(let value):
        return AttributeValue.int(Int(value))
    case .int64(let value):
        return AttributeValue.int(Int(value))
    case .double(let value):
        return AttributeValue.double(value)
    case .bool(let value):
        return AttributeValue.bool(value)
    case .string(let value):
        return AttributeValue.string(value)
    case .int32Array(let values):
        return AttributeValue.array(
            AttributeArray(values: values.map { AttributeValue.int(Int($0)) }))
    case .int64Array(let values):
        return AttributeValue.array(
            AttributeArray(values: values.map { AttributeValue.int(Int($0)) }))
    case .doubleArray(let values):
        return AttributeValue.array(
            AttributeArray(values: values.map { AttributeValue.double($0) }))
    case .boolArray(let values):
        return AttributeValue.array(AttributeArray(values: values.map { AttributeValue.bool($0) }))
    case .stringArray(let values):
        return AttributeValue.array(
            AttributeArray(values: values.map { AttributeValue.string($0) }))
    case .stringConvertible(let value):
        return AttributeValue.string(String(describing: value))
    case .stringConvertibleArray(let values):
        return AttributeValue.array(
            AttributeArray(values: values.map { AttributeValue.string(String(describing: $0)) }))
    case .__DO_NOT_SWITCH_EXHAUSTIVELY_OVER_THIS_ENUM_USE_DEFAULT_INSTEAD:
        return nil
    }
}

// MARK: - ServiceContext Extension
extension ServiceContext {
    /// Access the distributed tracing span stored in this context
    var distributedTracingSpan: (any Tracing.Span)? {
        self[DistributedTracingSpanKey.self]
    }
}

enum DistributedTracingSpanKey: ServiceContextKey {
    typealias Value = any Tracing.Span
    static let defaultValue: (any Tracing.Span)? = nil
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

// MARK: - SpanAttributes Extension
extension SpanAttributes {
    /// Access to internal attributes dictionary for conversion purposes
    var _attributes: [String: Tracing.SpanAttribute] {
        var result: [String: Tracing.SpanAttribute] = [:]
        self.forEach { key, value in
            result[key] = value
        }
        return result
    }
}
