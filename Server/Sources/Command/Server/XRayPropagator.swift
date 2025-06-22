import Foundation
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk

/// X-Ray trace context information
struct XRayContext {
    let traceId: TraceId
    let spanId: SpanId
    let sampled: Bool
}

/// A propagator for AWS X-Ray trace context.
///
/// This propagator extracts trace context from the AWS X-Ray trace header format.
struct XRayPropagator {
    /// The HTTP header key used for AWS X-Ray trace ID.
    private static let xRayTraceIDKey = "X-Amzn-Trace-Id"

    /// Extracts trace context from HTTP headers.
    ///
    /// - Parameter headers: The HTTP headers containing the X-Ray trace ID.
    /// - Returns: An XRayContext if extraction was successful, nil otherwise.
    static func extractTraceContext(from headers: [String: String]) -> XRayContext? {
        guard let xRayTraceID = headers[xRayTraceIDKey] ?? headers[xRayTraceIDKey.lowercased()]
        else {
            return nil
        }

        var traceIdHex: String?
        var spanIdHex: String?
        var sampled = false

        // Parse X-Ray trace header format: Root=1-XXXXXXXX-YYYYYYYYYYYYYYYYYYYYYYYY;Parent=ZZZZZZZZZZZZZZZZ;Sampled=0/1
        for field in xRayTraceID.split(separator: ";") {
            let trimmedField = field.trimmingCharacters(in: .whitespaces)

            if trimmedField.hasPrefix("Root=") {
                let rootValue = String(trimmedField.dropFirst(5))
                // Format: 1-XXXXXXXX-YYYYYYYYYYYYYYYYYYYYYYYY
                let components = rootValue.split(separator: "-")
                if components.count == 3 {
                    // Combine clock and random parts for the trace ID
                    traceIdHex = String(components[1] + components[2])
                }
            } else if trimmedField.hasPrefix("Parent=") {
                spanIdHex = String(trimmedField.dropFirst(7))
            } else if trimmedField.hasPrefix("Sampled=") {
                let sampledValue = String(trimmedField.dropFirst(8))
                sampled = sampledValue == "1"
            }
        }

        guard let traceIdHex = traceIdHex,
            let spanIdHex = spanIdHex
        else {
            return nil
        }

        // Convert hex strings to TraceId and SpanId
        // TraceId uses the built-in fromHexString initializer
        let traceId = TraceId(fromHexString: traceIdHex)
        // SpanId uses the built-in fromHexString initializer
        let spanId = SpanId(fromHexString: spanIdHex)

        return XRayContext(traceId: traceId, spanId: spanId, sampled: sampled)
    }
}
