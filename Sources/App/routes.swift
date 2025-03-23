import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get { req async throws in
        try await req.view.render("index", ["title": "Hello Vapor!"])
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    app.post("hello") { req in
        "POST hello"
    }

    app.put("hello") { req in
        "PUT hello"
    }

    app.delete("hello") { req in
        "DELETE hello"
    }

    try app.register(collection: TodoController())
}
