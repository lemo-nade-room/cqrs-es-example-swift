import Vapor
import OTel
import Instrumentation

/// Middleware that forces OpenTelemetry to flush spans after each request
/// This is crucial for serverless environments where the container might be frozen after request completion
struct OTelFlushMiddleware: AsyncMiddleware {
    let processor: any OTelSpanProcessor
    
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        
        do {
            request.logger.notice("[OTelFlushMiddleware] Flushing spans before Lambda freeze")
            try await processor.forceFlush()
            request.logger.notice("[OTelFlushMiddleware] Flush completed successfully")
        } catch {
            request.logger.error("[OTelFlushMiddleware] Failed to flush OpenTelemetry spans: \(error)")
        }
        
        return response
    }
}