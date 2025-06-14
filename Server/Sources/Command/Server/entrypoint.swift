import Logging
import NIOCore
import NIOPosix
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
//        try LoggingSystem.bootstrap(from: &env)
        
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label, metadataProvider: .otel)
            handler.logLevel = .trace
            return handler
        }

        let app = try await Application.make(env)

        let executorTakeoverSuccess =
            NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        app.logger.debug(
            "Tried to install SwiftNIO's EventLoopGroup as Swift's global concurrency executor",
            metadata: ["success": .stringConvertible(executorTakeoverSuccess)],
        )

        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
