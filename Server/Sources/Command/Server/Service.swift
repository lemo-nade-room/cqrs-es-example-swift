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
        logger.notice("[Healthcheck] Request received")
        return .ok(.init(body: .plainText("Command Server Working!")))
    }
}
