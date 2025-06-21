import Logging
import NIOCore
import NIOPosix
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        print("[DEBUG] 🚀 Starting CommandServer")

        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        let executorTakeoverSuccess =
            NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        app.logger.debug(
            "NIO executor takeover: \(executorTakeoverSuccess ? "✅" : "❌")"
        )

        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.error("❌ Fatal error: \(error)")
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
