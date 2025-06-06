import Vapor

func configure(_ app: Application) async throws {
    app.get("query", "healthcheck") { _ in
        "Query World!"
    }
}
