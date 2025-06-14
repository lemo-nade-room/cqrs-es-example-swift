import Foundation
import OTel
import AWSSDKHTTPAuth
import ClientRuntime
import SmithyHTTPAPI
import SwiftProtobuf

actor XRayOTelSpanExporter: OTelSpanExporter {
    /// HTTP client used to send requests (e.g., AsyncHTTPClient via AWS SDK).
    let client: any HTTPClient
    /// Endpoint URL for AWS X-Ray OTLP traces (e.g. "https://xray.ap-northeast-1.amazonaws.com/v1/traces").
    let url: URL
    /// Whether the exporter has been shut down.
    private var shutdowned = false

    init(client: any HTTPClient, url: URL) {
        self.client = client
        self.url = url
    }

    /// Exports a batch of finished spans to the X-Ray OTLP endpoint.
    func export(_ batch: some Collection<OTel.OTelFinishedSpan> & Sendable) async throws {
        // If exporter is shut down, throw error (cannot use after shutdown).
        if shutdowned {
            throw OTelSpanExporterAlreadyShutDownError()
        }

        // Group spans by resource and instrumentation scope to build OTLP request.
        var tracesData = Opentelemetry_Proto_Trace_V1_TracesData()
        for span in batch {
            // Determine resource and scope for this span
            let resource = span.resource  // OTelResource associated with span (from tracer)
            let scopeInfo = span.instrumentationScope  // instrumentation scope (name & version)
            // Find or create a ResourceSpans entry for this resource
            var resourceSpans: Opentelemetry_Proto_Trace_V1_ResourceSpans
            if let idx = tracesData.resourceSpans.firstIndex(where: { $0.resource.attributes == resource.attributes }) {
                resourceSpans = tracesData.resourceSpans[idx]
            } else {
                resourceSpans = Opentelemetry_Proto_Trace_V1_ResourceSpans()
                // Convert resource to proto form
                resourceSpans.resource = convertResource(resource)
                tracesData.resourceSpans.append(resourceSpans)
            }
            // Find or create ScopeSpans for this instrumentation scope within the resource
            var scopeSpans: Opentelemetry_Proto_Trace_V1_ScopeSpans
            if let idx = resourceSpans.scopeSpans.firstIndex(where: { $0.scope.name == scopeInfo.name && $0.scope.version == scopeInfo.version }) {
                scopeSpans = resourceSpans.scopeSpans[idx]
            } else {
                scopeSpans = Opentelemetry_Proto_Trace_V1_ScopeSpans()
                scopeSpans.scope = convertInstrumentationScope(scopeInfo)
                resourceSpans.scopeSpans.append(scopeSpans)
            }
            // Convert span to proto and add to scopeSpans
            scopeSpans.spans.append(convertSpan(span))
        }

        // Serialize the OTLP trace data to protobuf binary
        let payloadData = try tracesData.serializedData()

        // Prepare HTTP request (POST with protobuf payload)
        var requestBuilder = HTTPRequestBuilder()
        requestBuilder.withMethod(.post)
                      .withURL(url)
                      .withHeader(name: "Content-Type", value: "application/x-protobuf")  // OTLP binary format:contentReference[oaicite:2]{index=2}
                      .withBody(Data(payloadData))

        // Sign the request using AWS SigV4 (adds Authorization, x-amz-date, etc.)
        let signer = AWSSigV4Signer()  // uses default credentials provider (e.g., env or IAM)
        let region = extractRegion(from: url)
        let signedRequest = try signer.sign(
            request: requestBuilder.build(),
            signingName: "xray",
            signingRegion: region
        )
        // **Remark:** Standard OTLP doesn’t require auth headers, but AWS OTLP endpoints demand SigV4 signing:contentReference[oaicite:3]{index=3}.

        // Send the signed HTTP request using the HTTP client
        let response = try await client.execute(request: signedRequest)
        // Check HTTP status code for success (200 OK or 204 No Content are acceptable)
        if let statusCode = response.statusCode?.rawValue {
            if statusCode < 200 || statusCode >= 300 {
                throw OTelSpanExporterError("X-Ray exporter received HTTP \(statusCode)")
            }
        }
    }

    /// Flushes the exporter (ensures any pending spans are sent out).
    func forceFlush() async throws {
        // For this exporter, spans are sent immediately, so no buffering to flush.
    }

    /// Shuts down the exporter, releasing any resources.
    func shutdown() async {
        shutdowned = true
    }

    // MARK: - Helper conversion functions

    /// Convert OTelResource to Opentelemetry_Proto_Resource_V1_Resource
    private func convertResource(_ resource: OTelResource) -> Opentelemetry_Proto_Resource_V1_Resource {
        var protoRes = Opentelemetry_Proto_Resource_V1_Resource()
        for (key, value) in resource.attributes {
            protoRes.attributes.append(protoKeyValue(key: key, value: value))
        }
        return protoRes
    }

    /// Convert instrumentation scope info to Opentelemetry_Proto_Common_V1_InstrumentationScope
    private func convertInstrumentationScope(_ scope: InstrumentationScope) -> Opentelemetry_Proto_Common_V1_InstrumentationScope {
        var protoScope = Opentelemetry_Proto_Common_V1_InstrumentationScope()
        protoScope.name = scope.name
        protoScope.version = scope.version ?? ""
        return protoScope
    }

    /// Convert a finished span to Opentelemetry_Proto_Trace_V1_Span
    private func convertSpan(_ span: OTelFinishedSpan) -> Opentelemetry_Proto_Trace_V1_Span {
        var protoSpan = Opentelemetry_Proto_Trace_V1_Span()
        // IDs (OTelTraceID / OTelSpanID to Data)
        protoSpan.traceID = Data(span.spanContext.traceID.bytes)
        protoSpan.spanID = Data(span.spanContext.spanID.bytes)
        if let parentID = span.parentSpanID {
            protoSpan.parentSpanID = Data(parentID.bytes)
        }
        // Basic properties
        protoSpan.name = span.operationName
        protoSpan.kind = convertSpanKind(span.kind)
        protoSpan.startTimeUnixNano = span.startTimeNanoseconds
        protoSpan.endTimeUnixNano = span.endTimeNanoseconds
        // Attributes
        for (key, val) in span.attributes {
            protoSpan.attributes.append(protoKeyValue(key: key, value: val))
        }
        protoSpan.droppedAttributesCount = UInt32(span.droppedAttributesCount)
        // Events
        for event in span.events {
            protoSpan.events.append(convertEvent(event))
        }
        protoSpan.droppedEventsCount = UInt32(span.droppedEventsCount)
        // Links
        for link in span.links {
            protoSpan.links.append(convertLink(link))
        }
        protoSpan.droppedLinksCount = UInt32(span.droppedLinksCount)
        // Status (code and message)
        if let status = span.status {
            var protoStatus = Opentelemetry_Proto_Trace_V1_Status()
            protoStatus.code = convertStatusCode(status.code)
            protoStatus.message = status.message ?? ""
            protoSpan.status = protoStatus
        }
        return protoSpan
    }

    /// Convert span event to proto Span.Event
    private func convertEvent(_ event: OTelSpanEvent) -> Opentelemetry_Proto_Trace_V1_Span.Event {
        var protoEvent = Opentelemetry_Proto_Trace_V1_Span.Event()
        protoEvent.timeUnixNano = event.timestampNanoseconds
        protoEvent.name = event.name
        for (key, val) in event.attributes {
            protoEvent.attributes.append(protoKeyValue(key: key, value: val))
        }
        protoEvent.droppedAttributesCount = UInt32(event.droppedAttributesCount)
        return protoEvent
    }

    /// Convert span link to proto Span.Link
    private func convertLink(_ link: OTelSpanLink) -> Opentelemetry_Proto_Trace_V1_Span.Link {
        var protoLink = Opentelemetry_Proto_Trace_V1_Span.Link()
        protoLink.traceID = Data(link.context.traceID.bytes)
        protoLink.spanID = Data(link.context.spanID.bytes)
        protoLink.traceState = link.context.traceState // W3C trace state string
        for (key, val) in link.attributes {
            protoLink.attributes.append(protoKeyValue(key: key, value: val))
        }
        protoLink.droppedAttributesCount = UInt32(link.droppedAttributesCount)
        // Set trace flags & remote marker in link flags if needed
        protoLink.flags = link.context.isRemote ? 0x100 | (link.context.traceFlags & 0xFF) : (link.context.traceFlags & 0xFF)
        return protoLink
    }

    /// Convert a key-value attribute to proto KeyValue
    private func protoKeyValue(key: String, value: OTelAttributeValue) -> Opentelemetry_Proto_Common_V1_KeyValue {
        var kv = Opentelemetry_Proto_Common_V1_KeyValue()
        kv.key = key
        // Convert value based on type
        switch value {
        case .string(let str):
            kv.value.stringValue = str
        case .bool(let b):
            kv.value.boolValue = b
        case .int(let i):
            kv.value.intValue = i
        case .double(let d):
            kv.value.doubleValue = d
        case .stringArray(let arr):
            // Convert string array to AnyValue.arrayValue
            var arrayVal = Opentelemetry_Proto_Common_V1_ArrayValue()
            for s in arr { arrayVal.values.append(Opentelemetry_Proto_Common_V1_AnyValue.with { $0.stringValue = s }) }
            kv.value.arrayValue = arrayVal
        case .intArray(let arr):
            var arrayVal = Opentelemetry_Proto_Common_V1_ArrayValue()
            for num in arr { arrayVal.values.append(Opentelemetry_Proto_Common_V1_AnyValue.with { $0.intValue = num }) }
            kv.value.arrayValue = arrayVal
        case .doubleArray(let arr):
            var arrayVal = Opentelemetry_Proto_Common_V1_ArrayValue()
            for num in arr { arrayVal.values.append(Opentelemetry_Proto_Common_V1_AnyValue.with { $0.doubleValue = num }) }
            kv.value.arrayValue = arrayVal
        case .boolArray(let arr):
            var arrayVal = Opentelemetry_Proto_Common_V1_ArrayValue()
            for b in arr { arrayVal.values.append(Opentelemetry_Proto_Common_V1_AnyValue.with { $0.boolValue = b }) }
            kv.value.arrayValue = arrayVal
        }
        return kv
    }

    /// Map OTel span kind to proto enum
    private func convertSpanKind(_ kind: OTelSpanKind) -> Opentelemetry_Proto_Trace_V1_Span.SpanKind {
        switch kind {
        case .internal: return .internal
        case .server:   return .server
        case .client:   return .client
        case .producer: return .producer
        case .consumer: return .consumer
        }
    }

    /// Map OTel status code to proto Status.StatusCode
    private func convertStatusCode(_ code: OTelStatusCode) -> Opentelemetry_Proto_Trace_V1_Status.StatusCode {
        switch code {
        case .unset: return .unset
        case .ok:    return .ok
        case .error: return .error
        }
    }

    /// Extract AWS region (e.g. "ap-northeast-1") from the X-Ray endpoint URL host.
    private func extractRegion(from url: URL) -> String {
        // Host format: "xray.<region>.amazonaws.com"
        let host = url.host ?? ""
        // Example host "xray.ap-northeast-1.amazonaws.com" -> region "ap-northeast-1"
        let parts = host.split(separator: ".")
        // Usually, parts[0] = "xray", parts[1] = region
        if parts.count > 1, parts[0] == "xray" {
            return String(parts[1])
        }
        // Fallback: try environment AWS_REGION
        if let envRegion = ProcessInfo.processInfo.environment["AWS_REGION"] {
            return envRegion
        }
        return "us-east-1" // default if unable to determine
    }
}
