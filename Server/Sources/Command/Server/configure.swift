import Vapor

func configure(_ app: Application) async throws {
    app.get("command") { _ in
        "Command World!"
    }
}
