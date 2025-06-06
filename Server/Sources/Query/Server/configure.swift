import Vapor

func configure(_ app: Application) async throws {
    app.get("query") { _ in
        "Query World!"
    }
}
