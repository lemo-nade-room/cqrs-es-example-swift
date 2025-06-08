import Vapor

func configure(_ app: Application) async throws {
    app.get("command", "healthcheck") { _ in
        "Command Running!"
    }

    app.get("Stage", "command", "healthcheck") { _ in
        "Stage Command Running"
    }
}
