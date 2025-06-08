import OpenAPIRuntime
import OpenAPIVapor
import Vapor

func configure(_ app: Application) async throws {
    // ================================
    // OpenAPI Vapor Transport
    // ================================
    let transport = VaporTransport(routesBuilder: app)
    let service = Service()
    let serverURL: URL =
        switch Environment.get("SERVER") {
        case "Staging": try Servers.Server2.url()
        default: try Servers.Server1.url()
        }

    try service.registerHandlers(on: transport, serverURL: serverURL)

    // ================================
    // HTTP Server Configuration
    // ================================
    if app.environment == .development {
        app.http.server.configuration.port = 3001
    }
}
