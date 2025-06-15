import Foundation
import Logging

/// X-Rayリクエストのデバッグ情報を詳細に出力する
func debugXRayRequest() {
    let logger = Logger(label: "XRayDebug")
    
    logger.notice("=== X-Ray Request Debug Information ===")
    
    // 1. 環境変数の確認
    logger.notice("Environment Variables:")
    let xrayVars = [
        "_X_AMZN_TRACE_ID",
        "AWS_XRAY_CONTEXT_MISSING",
        "AWS_XRAY_DAEMON_ADDRESS",
        "AWS_XRAY_TRACING_NAME",
        "AWS_REGION",
        "AWS_LAMBDA_FUNCTION_NAME",
        "AWS_LAMBDA_FUNCTION_VERSION",
        "AWS_EXECUTION_ENV"
    ]
    
    for varName in xrayVars {
        if let value = ProcessInfo.processInfo.environment[varName] {
            logger.notice("  \(varName): \(value)")
        } else {
            logger.notice("  \(varName): <not set>")
        }
    }
    
    // 2. Lambda実行環境の確認
    if let traceID = ProcessInfo.processInfo.environment["_X_AMZN_TRACE_ID"] {
        logger.notice("Lambda Trace ID format: \(traceID)")
        
        // トレースIDの解析
        let components = traceID.split(separator: ";")
        for component in components {
            if component.hasPrefix("Root=") {
                let root = String(component.dropFirst(5))
                logger.notice("  Root trace ID: \(root)")
                
                // X-Ray形式の検証
                let parts = root.split(separator: "-")
                if parts.count == 3 && parts[0] == "1" {
                    logger.notice("  Valid X-Ray format: version=\(parts[0]), timestamp=\(parts[1]), random=\(parts[2])")
                } else {
                    logger.error("  Invalid X-Ray format!")
                }
            }
        }
    }
    
    // 3. VPC/ネットワーク設定の確認
    logger.notice("Network Configuration:")
    
    // /etc/resolv.conf の確認（DNS設定）
    if let resolv = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) {
        logger.notice("DNS Configuration:")
        logger.notice("\(resolv)")
    }
    
    // 4. X-Rayエンドポイントの解決確認
    let xrayHost = "xray.ap-northeast-1.amazonaws.com"
    logger.notice("Resolving X-Ray endpoint: \(xrayHost)")
    
    logger.notice("=== End Debug Information ===")
}