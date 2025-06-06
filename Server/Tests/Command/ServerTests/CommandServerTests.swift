import Fluent
import Testing
import VaporTesting

@testable import CommandServer

@Suite struct CommandServerTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await test(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Test Command World Route")
    func commandWorld() async throws {
        try await withApp { app in
            let res = try await app.testing().sendRequest(.GET, "command")

            #expect(res.status == .ok)
            #expect(res.body.string == "Command World!")
        }
    }
}
