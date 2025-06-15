import Foundation
import OTel
import W3CTraceContext

/// X-Ray compatible ID generator that generates trace IDs in X-Ray format
/// Format: 1-{8 hex chars timestamp}-{24 hex chars random}
/// Example: 1-5f4dc383-70e8e0e63340343f13f40ea0
public struct XRayIDGenerator: OTelIDGenerator {
    public init() {}
    
    public func nextTraceID() -> TraceID {
        // Lambda環境の場合、既存のX-RayトレースIDを使用
        if let lambdaTraceHeader = ProcessInfo.processInfo.environment["_X_AMZN_TRACE_ID"] {
            // トレースヘッダーを解析
            // 形式: Root=1-684e7cbb-176c922523d069c201a47711;Parent=...;Sampled=...
            let components = lambdaTraceHeader.split(separator: ";")
            if let rootComponent = components.first(where: { $0.hasPrefix("Root=") }) {
                let rootValue = String(rootComponent.dropFirst(5)) // "Root="を削除
                // X-Ray形式: 1-684e7cbb-176c922523d069c201a47711
                // W3C形式に変換: 684e7cbb176c922523d069c201a47711
                let parts = rootValue.split(separator: "-")
                if parts.count == 3 && parts[0] == "1" {
                    // タイムスタンプとランダム部分を結合
                    let w3cHex = String(parts[1]) + String(parts[2])
                    
                    // 16進数文字列をバイト配列に変換
                    if let traceID = parseTraceID(from: w3cHex) {
                        return traceID
                    }
                }
            }
        }
        
        // Lambda環境でない場合、または解析に失敗した場合は通常のランダムIDを生成
        return TraceID.random()
    }
    
    public func nextSpanID() -> SpanID {
        // X-Ray uses 64-bit span IDs, which matches W3C format
        return SpanID.random()
    }
    
    /// X-Ray形式の16進数文字列からTraceIDを作成
    private func parseTraceID(from hexString: String) -> TraceID? {
        guard hexString.count == 32 else { return nil }
        
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        
        for _ in 0..<16 {
            let nextIndex = hexString.index(index, offsetBy: 2)
            if let byte = UInt8(hexString[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }
        
        guard bytes.count == 16 else { return nil }
        
        return TraceID(bytes: .init((
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
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