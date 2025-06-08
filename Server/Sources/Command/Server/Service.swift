import OpenAPIRuntime

struct Service: APIProtocol {
    func getV1Healthcheck(
        _ input: Operations.GetV1Healthcheck.Input
    ) async throws -> Operations.GetV1Healthcheck.Output {
        .ok(.init(body: .plainText("Command Server Working!")))
    }
}
