import Instrumentation
import Logging
import OTel
import RegexBuilder
import W3CTraceContext

/// A propagator for AWS X-Ray trace context.
///
/// This propagator extracts and injects trace context from/to the AWS X-Ray trace header format.
/// It implements the OTelPropagator protocol to provide compatibility with OpenTelemetry instrumentation.
struct XRayOTelPropagator: OTelPropagator {

    private var logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }

    /// The HTTP header key used for AWS X-Ray trace ID.
    ///
    /// This key is used when extracting and injecting trace context from/to HTTP headers.
    private static var xRayTraceIDKey: String { "x-amzn-trace-id" }

    /// Extracts span context from a carrier using the provided extractor.
    ///
    /// This method parses the AWS X-Ray trace header format and converts it to an OTel span context.
    ///
    /// - Parameters:
    ///   - carrier: The carrier containing the propagation data.
    ///   - extractor: The extractor used to extract data from the carrier.
    /// - Returns: An OTelSpanContext if extraction was successful, nil otherwise.
    /// - Throws: An error if extraction fails.
    func extractSpanContext<Carrier, Extract: Extractor>(
        from carrier: Carrier,
        using extractor: Extract
    ) throws -> OTelSpanContext? where Extract.Carrier == Carrier {
        guard
            let xRayTraceID = extractor.extract(key: Self.xRayTraceIDKey, from: carrier)
        else {
            logger.debug("X-Ray trace ID header not found in carrier")
            return nil
        }
        logger.debug("Found X-Ray trace ID: \(xRayTraceID)")

        var traceID: TraceID? = nil
        var spanID: SpanID? = nil
        var flags: TraceFlags? = nil

        let rootFieldRegex = makeRootFieldRegex()
        let parentFieldRegex = makeParentFieldRegex()
        let sampledFieldRegex = makeSampledFieldRegex()

        for field in xRayTraceID.split(separator: ";") {
            if let (_, clock, random) = try rootFieldRegex.wholeMatch(in: field)?.output {
                traceID = makeTraceID(clock: clock, random: random)
                logger.trace("Extracted traceID: \(traceID!)")
                continue
            }
            if let (_, hex) = try parentFieldRegex.wholeMatch(in: field)?.output {
                spanID = makeSpanID(hex: hex)
                logger.trace("Extracted spanID: \(spanID!)")
                continue
            }
            if let (_, n) = try sampledFieldRegex.wholeMatch(in: field)?.output {
                flags = n == "1" ? .sampled : []
                logger.trace("Extracted flags: \(flags!)")
                continue
            }
        }

        guard let traceID, let spanID, let flags else {
            logger.debug("Failed to extract complete trace context")
            logger.trace("traceID: \(traceID == nil ? "missing" : "present"), spanID: \(spanID == nil ? "missing" : "present"), flags: \(flags == nil ? "missing" : "present")")
            return nil
        }

        // Create the trace context
        let traceContext = W3CTraceContext.TraceContext(
            traceID: traceID,
            spanID: spanID,
            flags: flags,
            state: .init()
        )
        
        logger.trace("Created trace context: \(traceContext)")

        // Return the remote span context
        return OTelSpanContext.remote(traceContext: traceContext)
    }

    /// Injects span context into a carrier using the provided injector.
    ///
    /// This method converts an OTel span context to the AWS X-Ray trace header format
    /// and injects it into the carrier.
    ///
    /// - Parameters:
    ///   - spanContext: The OTel span context to inject.
    ///   - carrier: The carrier to inject the context into.
    ///   - injector: The injector used to inject data into the carrier.
    func inject<Carrier, Inject>(
        _ spanContext: OTelSpanContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Inject: Injector, Inject.Carrier == Carrier {
        let traceIDBytes = spanContext.traceID.bytes

        let root = "Root=1-\(traceIDBytes[0..<4].hexString)-\(traceIDBytes[4..<16].hexString)"
        let parent = "Parent=\(spanContext.spanID)"
        let sampled = "Sampled=\(spanContext.traceFlags.contains(.sampled) ? 1 : 0)"

        injector.inject("\(root);\(parent);\(sampled)", forKey: Self.xRayTraceIDKey, into: &carrier)
        logger.trace("Injected X-Ray trace header: \(root);\(parent);\(sampled)")
    }

}

/// Creates a regex pattern to match the Root field in an AWS X-Ray trace header.
///
/// The Root field has the format "Root=1-<8-character-hex>-<24-character-hex>".
///
/// - Returns: A regex that captures the two hex parts of the Root field.
private func makeRootFieldRegex() -> Regex<(Substring, Substring, Substring)> {
    .init {
        Anchor.startOfLine
        "Root=1-"
        Capture {
            Repeat(count: 8) {
                .hexDigit
            }
        }
        "-"
        Capture {
            Repeat(count: 24) {
                .hexDigit
            }
        }
        Anchor.endOfLine
    }
}

/// Creates a regex pattern to match the Parent field in an AWS X-Ray trace header.
///
/// The Parent field has the format "Parent=<16-character-hex>".
///
/// - Returns: A regex that captures the hex part of the Parent field.
private func makeParentFieldRegex() -> Regex<(Substring, Substring)> {
    .init {
        Anchor.startOfLine
        "Parent="
        Capture {
            Repeat(count: 16) {
                .hexDigit
            }
        }
        Anchor.endOfLine
    }
}

/// Creates a regex pattern to match the Sampled field in an AWS X-Ray trace header.
///
/// The Sampled field has the format "Sampled=<0|1>".
///
/// - Returns: A regex that captures the sampling decision (0 or 1).
private func makeSampledFieldRegex() -> Regex<(Substring, Substring)> {
    .init {
        Anchor.startOfLine
        "Sampled="
        Capture {
            ChoiceOf {
                "0"
                "1"
            }
        }
        Anchor.endOfLine
    }
}

/// Creates a TraceID from the clock and random parts of an AWS X-Ray trace ID.
///
/// - Parameters:
///   - clock: The 8-character hex clock part of the trace ID.
///   - random: The 24-character hex random part of the trace ID.
/// - Returns: A TraceID constructed from the combined hex values.
private func makeTraceID(clock: Substring, random: Substring) -> TraceID {
    let bytes = (clock + random).toUInt8Array(count: 32)
    return .init(
        bytes: .init(
            (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    )
}

/// Creates a SpanID from a hex string.
///
/// - Parameter hex: The 16-character hex string representing the span ID.
/// - Returns: A SpanID constructed from the hex value.
private func makeSpanID(hex: Substring) -> SpanID {
    let bytes = hex.toUInt8Array(count: 16)
    return .init(
        bytes: .init(
            (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
            )
        )
    )
}

extension Substring {
    /// Converts a hex string to an array of UInt8 values.
    ///
    /// - Parameter count: The number of characters in the hex string.
    /// - Returns: An array of UInt8 values parsed from the hex string.
    fileprivate func toUInt8Array(count: Int) -> [UInt8] {
        stride(from: 0, to: count, by: 2).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: 2)
            return UInt8(self[start..<end], radix: 16)!
        }
    }
}

extension Collection where Element == UInt8 {
    /// Converts an array of UInt8 values to a hex string.
    ///
    /// - Returns: A string representation of the bytes in hexadecimal format.
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
