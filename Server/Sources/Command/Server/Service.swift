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
        logger.info("🏥 Healthcheck requested")

        await withSpan("healthcheck") { span in
            span.updateAttributes { attributes in
                attributes["service.name"] = "command-server"
                attributes["endpoint"] = "/v1/healthcheck"
            }

            await withSpan("DB読み込み") { dbReadSpan in
                dbReadSpan.updateAttributes { attributes in
                    attributes["db.operation"] = "read"
                    attributes["db.table"] = "users"
                }

                // DBの読み込みをシミュレート（1秒待機）
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                dbReadSpan.setStatus(.init(code: .ok))
            }

            await withSpan("DB書き込み") { dbWriteSpan in
                dbWriteSpan.updateAttributes { attributes in
                    attributes["db.operation"] = "write"
                    attributes["db.table"] = "health_logs"
                }

                // DBの書き込みをシミュレート（0.5秒待機）
                try? await Task.sleep(nanoseconds: 500_000_000)
                dbWriteSpan.setStatus(.init(code: .ok))
            }

            span.setStatus(.init(code: .ok))
        }
        return .ok(.init(body: .plainText("Command Server Working!")))
    }
}

// MARK: - Debug logging helper
extension Service {
    private func logDebug(_ message: String) {
        logger.debug("[DEBUG] \(message)")
    }
}
