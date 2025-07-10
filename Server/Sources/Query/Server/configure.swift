import Vapor

func configure(_ app: Application) async throws {
    app.get("query", "healthcheck") { _ in
        "Query Running - v7 (No ENTRYPOINT)"
    }

    app.get("Stage", "query", "healthcheck") { _ in
        "Stage Query Running"
    }

    // ================================
    // Lambda Web Adapter
    // ================================
    app.get { _ in "It works!" }
}
