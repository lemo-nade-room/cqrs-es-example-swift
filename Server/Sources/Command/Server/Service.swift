import OpenAPIRuntime
import Logging
import Vapor
import Foundation
import Tracing
import Instrumentation

struct Service: APIProtocol {
    var logger: Logger
    
    @TaskLocal static var req: Vapor.Request?
    
    func getV1Healthcheck(
        _ input: Operations.GetV1Healthcheck.Input
    ) async throws -> Operations.GetV1Healthcheck.Output {
        logger.info("💚 INFOです")
        logger.notice("💚 NOTICEです")
        return try await InstrumentationSystem.tracer.withSpan("Sleep") { span in
            logger.warning("💚 WARNINGです")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return .ok(.init(body: .plainText("Command Server Working!")))
        }
    }
}
