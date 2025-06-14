import OpenAPIRuntime
import Logging

struct Service: APIProtocol {
    var logger: Logger
    
    func getV1Healthcheck(
        _ input: Operations.GetV1Healthcheck.Input
    ) async throws -> Operations.GetV1Healthcheck.Output {
        logger.info("💚 INFOです")
        logger.notice("💚 NOTICEです")
        logger.warning("💚 WARNINGです")
        return .ok(.init(body: .plainText("Command Server Working!")))
    }
}
