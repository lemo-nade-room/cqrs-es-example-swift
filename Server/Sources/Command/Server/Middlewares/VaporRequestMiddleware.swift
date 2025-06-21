import Vapor

struct VaporRequestMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response
    {
        try await Service.$req.withValue(request) {
            try await next.respond(to: request)
        }
    }
}
