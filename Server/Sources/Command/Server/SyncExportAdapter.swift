import AsyncHTTPClient
import Foundation
import NIOCore
import OpenTelemetrySdk

/// AsyncHTTPClientを同期的にラップするアダプター
final class SyncExportAdapter {
    private let httpClient: HTTPClient
    private let timeout: TimeInterval
    
    init(httpClient: HTTPClient, timeout: TimeInterval = 5.0) {
        self.httpClient = httpClient
        self.timeout = timeout
    }
    
    /// 非同期HTTPリクエストを同期的に実行
    func executeSync(_ request: HTTPClientRequest) -> Result<HTTPClientResponse, Error> {
        let group = DispatchGroup()
        var result: Result<HTTPClientResponse, Error>?
        
        group.enter()
        
        // 独立したTaskで非同期処理を実行
        Task.detached(priority: .high) {
            do {
                let response = try await self.httpClient.execute(
                    request, 
                    timeout: .seconds(Int64(self.timeout))
                )
                result = .success(response)
            } catch {
                result = .failure(error)
            }
            group.leave()
        }
        
        // タイムアウト付きで待機
        let waitResult = group.wait(timeout: .now() + timeout)
        
        if waitResult == .timedOut {
            return .failure(ExportError.timeout)
        }
        
        return result ?? .failure(ExportError.timeout)
    }
}