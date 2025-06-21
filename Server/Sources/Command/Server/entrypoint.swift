import Logging
import NIOCore
import NIOPosix
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        print("[DEBUG] Starting entrypoint.main()")
        print("[DEBUG] Process arguments: \(CommandLine.arguments)")
        
        var env = try Environment.detect()
        print("[DEBUG] Detected environment: \(env.name)")
        
        try LoggingSystem.bootstrap(from: &env)
        print("[DEBUG] LoggingSystem bootstrapped")

        print("[DEBUG] Creating Application")
        let app = try await Application.make(env)
        print("[DEBUG] Application created")

        let executorTakeoverSuccess =
            NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        app.logger.debug(
            "Tried to install SwiftNIO's EventLoopGroup as Swift's global concurrency executor",
            metadata: ["success": .stringConvertible(executorTakeoverSuccess)],
        )
        print("[DEBUG] NIO executor takeover: \(executorTakeoverSuccess)")

        do {
            print("[DEBUG] Calling configure()")
            try await configure(app)
            print("[DEBUG] configure() completed")
            
            print("[DEBUG] Executing application")
            try await app.execute()
            print("[DEBUG] Application execution completed")
        } catch {
            print("[DEBUG] Error occurred: \(error)")
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        print("[DEBUG] Shutting down application")
        try await app.asyncShutdown()
        print("[DEBUG] Application shutdown completed")
    }
}
