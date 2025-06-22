import ServiceContextModule
import Vapor

struct VaporRequestMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response
    {
        try await Service.$req.withValue(request) {
            // ServiceContext.withValueを使用してServiceContextを伝搬
            try await ServiceContext.withValue(request.serviceContext) {
                try await next.respond(to: request)
            }
        }
    }
}
