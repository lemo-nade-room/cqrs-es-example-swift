import Foundation
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk

/// X-Ray trace context information
struct XRayContext {
    let traceId: TraceId
    let spanId: SpanId
    let sampled: Bool
    let xrayTraceId: String  // X-Ray形式のトレースID (例: 1-XXXXXXXX-YYYYYYYYYYYYYYYYYYYYYYYY)
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
        var xrayTraceIdFull: String?

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
                    // Store the full X-Ray format trace ID
                    xrayTraceIdFull = rootValue
                    print(
                        "🔍 X-Ray trace extraction - Full: \(rootValue), Hex: \(traceIdHex ?? "nil")"
                    )
                }
            } else if trimmedField.hasPrefix("Parent=") {
                spanIdHex = String(trimmedField.dropFirst(7))
                print("🔍 X-Ray parent span: \(spanIdHex ?? "nil")")
            } else if trimmedField.hasPrefix("Sampled=") {
                let sampledValue = String(trimmedField.dropFirst(8))
                sampled = sampledValue == "1"
                print("🔍 X-Ray sampled: \(sampled)")
            }
        }

        guard let traceIdHex = traceIdHex,
            let spanIdHex = spanIdHex,
            let xrayTraceIdFull = xrayTraceIdFull
        else {
            print("❌ Failed to extract X-Ray trace context - missing required fields")
            return nil
        }

        // Convert hex strings to TraceId and SpanId
        // TraceId uses the built-in fromHexString initializer
        let traceId = TraceId(fromHexString: traceIdHex)
        // SpanId uses the built-in fromHexString initializer
        let spanId = SpanId(fromHexString: spanIdHex)

        print(
            "✅ X-Ray context created - TraceId: \(traceId.hexString), SpanId: \(spanId.hexString)")
        return XRayContext(
            traceId: traceId, spanId: spanId, sampled: sampled, xrayTraceId: xrayTraceIdFull)
    }
}

// MARK: - TraceId Extension for X-Ray Format Conversion
extension TraceId {
    /// X-Ray形式のトレースIDに変換する
    /// OpenTelemetryのTraceIdは16バイト（32文字の16進数）
    /// X-Rayは 1-XXXXXXXX-YYYYYYYYYYYYYYYYYYYYYYYY 形式
    /// XXXXXXXXは8文字（タイムスタンプ）、YYYYは24文字（ランダム）
    var xrayTraceId: String {
        let hex = self.hexString
        // 16バイトのトレースIDを分割
        // 最初の8文字をタイムスタンプ部分、残りの24文字をランダム部分として使用
        let timestamp = String(hex.prefix(8))
        let random = String(hex.suffix(24))
        return "1-\(timestamp)-\(random)"
    }
}
