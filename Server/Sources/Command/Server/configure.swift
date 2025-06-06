import Vapor

func configure(_ app: Application) async throws {
    app.get("command", "healthcheck") { _ in
        "Command World!"
    }
}
