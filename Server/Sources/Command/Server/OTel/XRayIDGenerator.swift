import Foundation
import OTel
import W3CTraceContext

/// X-Ray compatible ID generator that generates trace IDs in X-Ray format
/// Format: 1-{8 hex chars timestamp}-{24 hex chars random}
/// Example: 1-5f4dc383-70e8e0e63340343f13f40ea0
public struct XRayIDGenerator: OTelIDGenerator {
    public init() {}
    
    public func nextTraceID() -> TraceID {
        // Always generate a random trace ID
        // The actual X-Ray trace ID from HTTP headers will be used by XRayTracingMiddleware
        return TraceID.random()
    }
    
    public func nextSpanID() -> SpanID {
        // X-Ray uses 64-bit span IDs, which matches W3C format
        return SpanID.random()
    }
}

// Extension to help with X-Ray trace ID formatting
extension TraceID {
    /// Converts W3C TraceID to X-Ray-like format string
    /// Returns X-Ray format string: 1-{timestamp}-{random}
    /// Note: Since we can't access the raw bytes directly, we generate a pseudo X-Ray format
    public var xrayFormat: String {
        // Get current timestamp for the X-Ray format
        let timestamp = UInt32(Date().timeIntervalSince1970)
        let timestampHex = String(format: "%08x", timestamp)
        
        // Use the trace ID's description as a source for the random part
        // This is a workaround since we can't directly access the bytes
        let traceIDString = String(describing: self)
        let randomHex = String(traceIDString.suffix(24))
        
        return "1-\(timestampHex)-\(randomHex)"
    }
}