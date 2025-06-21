import Foundation
import Instrumentation
import Logging
import OpenAPIRuntime
import Tracing
import Vapor

struct Service: APIProtocol {
    var logger: Logger

    @TaskLocal static var req: Vapor.Request?

    func getV1Healthcheck(
        _ input: Operations.GetV1Healthcheck.Input
    ) async throws -> Operations.GetV1Healthcheck.Output {
        logger.debug("[DEBUG] Service.getV1Healthcheck called")
        logger.notice("[Healthcheck] Request received")

        await withSpan("healthcheck") { span in
            logger.debug("[DEBUG] Starting healthcheck span")
            span.updateAttributes { attributes in
                attributes["service.name"] = "command-server"
                attributes["endpoint"] = "/v1/healthcheck"
            }
            logger.debug("[DEBUG] Span attributes set")

            await withSpan("DB読み込み") { dbReadSpan in
                logger.debug("[DEBUG] Starting DB read span")
                dbReadSpan.updateAttributes { attributes in
                    attributes["db.operation"] = "read"
                    attributes["db.table"] = "users"
                }

                // DBの読み込みをシミュレート（1秒待機）
                logger.debug("[DEBUG] Simulating DB read (1s)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                dbReadSpan.setStatus(.init(code: .ok))
                logger.debug("[DEBUG] DB read span completed")
            }

            await withSpan("DB書き込み") { dbWriteSpan in
                logger.debug("[DEBUG] Starting DB write span")
                dbWriteSpan.updateAttributes { attributes in
                    attributes["db.operation"] = "write"
                    attributes["db.table"] = "health_logs"
                }

                // DBの書き込みをシミュレート（1秒弱に短縮）
                logger.debug("[DEBUG] Simulating DB write (0.5s)")
                try? await Task.sleep(nanoseconds: 500_000_000)

                dbWriteSpan.setStatus(.init(code: .ok))
                logger.debug("[DEBUG] DB write span completed")
            }

            span.setStatus(.init(code: .ok))
            logger.debug("[DEBUG] Healthcheck span completed")
        }

        logger.debug("[DEBUG] Returning healthcheck response")
        return .ok(.init(body: .plainText("Command Server Working!")))
    }
}

// MARK: - Debug logging helper
extension Service {
    private func logDebug(_ message: String) {
        logger.debug("[DEBUG] \(message)")
    }
}
