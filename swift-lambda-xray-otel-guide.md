# Swift on LambdaでAWS X-RayにOpenTelemetryトレースを送信する方法

## 概要

AWS Lambda上で動作するSwiftアプリケーションから、OpenTelemetry Protocol (OTLP)を使用してAWS X-Rayにトレースデータを送信する方法を解説します。Lambda Container Imagesを使用するため、ADOT Lambda Layerは使えませんが、アプリケーション内で直接OTLP送信を実装することで、Application Signalsと統合された詳細なトレーシングが可能になります。

## 必要な要件

### 1. AWS側の設定

#### X-Ray OTLP APIの有効化
X-RayでOTLPを使用するには、CloudWatch LogsをトレースデスティネーションとしてUpdateTraceSegmentDestination APIで有効化する必要があります。

```bash
# リージョンごとに一度実行（永続的な設定）
aws xray update-trace-segment-destination \
  --destination CloudWatchLogs \
  --region ap-northeast-1
```

#### CloudWatch Logsリソースポリシー
X-RayがCloudWatch Logsに書き込めるようにリソースポリシーを設定します。

```hcl
# Terraform/OpenTofu設定
resource "aws_cloudwatch_log_resource_policy" "xray_otlp" {
  policy_name = "xray-otlp-logs-policy"
  
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "xray.amazonaws.com"
        }
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream", 
          "logs:PutLogEvents"
        ]
        Resource = "*"  # X-Rayは`aws/spans`ロググループに書き込むため
      }
    ]
  })
}
```

#### Application Signals Discovery（オプション）
CloudWatch Application Signalsを有効化する場合：

```hcl
resource "awscc_applicationsignals_discovery" "this" {
  is_enabled = true
}
```

### 2. Lambda関数の設定

#### SAMテンプレート（template.yaml）

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31

Globals:
  Function:
    Timeout: 10  # コールドスタート対策で10秒に設定
    MemorySize: 128
    Architectures:
      - arm64

Resources:
  CommandServerFunction:
    Type: AWS::Serverless::Function
    Properties:
      PackageType: Image
      ImageUri: !Sub '${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/command-server-function:latest'
      Environment:
        Variables:
          # X-Ray設定
          AWS_XRAY_CONTEXT_MISSING: LOG_ERROR
          # OpenTelemetry設定
          OTEL_EXPORTER_OTLP_ENDPOINT: !Sub https://xray.${AWS::Region}.amazonaws.com
          OTEL_PROPAGATORS: xray
          OTEL_METRICS_EXPORTER: none
          OTEL_AWS_APPLICATION_SIGNALS_ENABLED: true
          OTEL_RESOURCE_ATTRIBUTES: service.name=CommandServer
      Policies:
        - AWSXRayDaemonWriteAccess
        - Version: '2012-10-17'
          Statement:
            - Effect: Allow
              Action:
                - cloudwatch:PutMetricData
              Resource: '*'
      Events:
        HttpApi:
          Type: HttpApi
          Properties:
            Method: ANY
            Path: /command/{proxy+}
```

### 3. Swift実装

#### Package.swift依存関係

```swift
dependencies: [
    // OpenTelemetry
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "1.0.0"),
    // HTTP Client (Lambda環境ではURLSessionが使えないため)
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.9.0"),
    // 暗号化（SigV4署名用）
    .package(url: "https://github.com/apple/swift-crypto.git", from: "2.0.0"),
    // Vapor
    .package(url: "https://github.com/vapor/vapor.git", from: "4.99.3"),
    .package(url: "https://github.com/swift-server/swift-aws-lambda-runtime.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-server/swift-aws-lambda-events.git", from: "0.5.0"),
],
```

#### AWS SigV4署名実装

```swift
import Crypto
import Foundation
import NIOHTTP1

struct AWSSigV4 {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let region: String
    let service: String

    func sign(request: inout HTTPClientRequest, payload: Data, date: Date) throws {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let dateString = dateFormatter.string(from: date)

        let shortDateFormatter = DateFormatter()
        shortDateFormatter.dateFormat = "yyyyMMdd"
        shortDateFormatter.timeZone = TimeZone(identifier: "UTC")
        let shortDate = shortDateFormatter.string(from: date)

        // Hostヘッダーを追加（必須）
        if let url = URL(string: request.url), let host = url.host {
            request.headers.add(name: "Host", value: host)
        }

        // 必須ヘッダーを追加
        request.headers.add(name: "X-Amz-Date", value: dateString)
        if let sessionToken = sessionToken {
            request.headers.add(name: "X-Amz-Security-Token", value: sessionToken)
        }

        // 正規リクエストを作成
        let canonicalRequest = createCanonicalRequest(
            method: request.method,
            url: request.url,
            headers: request.headers,
            payload: payload
        )

        // 署名文字列を作成
        let credentialScope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            dateString,
            credentialScope,
            SHA256.hash(data: canonicalRequest.data(using: .utf8)!).hexString
        ].joined(separator: "\n")

        // 署名キーを作成
        let signingKey = createSigningKey(
            secretKey: secretAccessKey,
            shortDate: shortDate,
            region: region,
            service: service
        )

        // 署名を計算
        let signature = HMAC<SHA256>.authenticationCode(
            for: stringToSign.data(using: .utf8)!,
            using: SymmetricKey(data: signingKey)
        ).hexString

        // Authorizationヘッダーを作成
        let signedHeaders = getSignedHeaders(headers: request.headers)
        let authorization = "AWS4-HMAC-SHA256 " +
            "Credential=\(accessKeyId)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), " +
            "Signature=\(signature)"

        request.headers.add(name: "Authorization", value: authorization)
    }

    // 実装の詳細は省略（正規リクエスト作成、署名キー生成など）
}
```

#### X-Ray OTLPエクスポーター実装

```swift
import AsyncHTTPClient
import Foundation
import NIOCore
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetrySdk

final class AWSXRayOTLPExporter: SpanExporter, @unchecked Sendable {
    private let endpoint: URL
    private let region: String
    private let httpClient: HTTPClient
    private let resource: Resource

    init(resource: Resource? = nil, eventLoopGroup: any EventLoopGroup) async throws {
        self.region = ProcessInfo.processInfo.environment["AWS_REGION"] ?? "us-east-1"
        self.endpoint = URL(string: "https://xray.\(self.region).amazonaws.com/v1/traces")!
        
        // リソース設定（service.nameが重要）
        if let resource = resource {
            self.resource = resource
        } else {
            var attributes: [String: AttributeValue] = [:]
            
            // OTEL_RESOURCE_ATTRIBUTESから読み込み
            if let resourceAttrs = ProcessInfo.processInfo.environment["OTEL_RESOURCE_ATTRIBUTES"] {
                for pair in resourceAttrs.split(separator: ",") {
                    let keyValue = pair.split(separator: "=", maxSplits: 1)
                    if keyValue.count == 2 {
                        let key = String(keyValue[0]).trimmingCharacters(in: .whitespaces)
                        let value = String(keyValue[1]).trimmingCharacters(in: .whitespaces)
                        attributes[key] = AttributeValue.string(value)
                    }
                }
            }
            
            self.resource = Resource(attributes: attributes)
        }
        
        // HTTPClient設定
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(
                timeout: HTTPClient.Configuration.Timeout(
                    connect: .seconds(5),
                    read: .seconds(10)
                )
            )
        )
    }

    func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil) -> SpanExporterResultCode {
        // Lambda環境でのみ送信
        guard ProcessInfo.processInfo.environment["AWS_EXECUTION_ENV"]?.starts(with: "AWS_Lambda") == true else {
            return .success
        }

        do {
            // Protobufに変換
            let resourceSpans = Opentelemetry_Proto_Trace_V1_ResourceSpans.with {
                $0.resource = Opentelemetry_Proto_Resource_V1_Resource.with {
                    $0.attributes = self.resource.attributes.map { key, value in
                        return Opentelemetry_Proto_Common_V1_KeyValue.with {
                            $0.key = key
                            $0.value = value.toProto()
                        }
                    }
                }
                
                $0.scopeSpans = [
                    Opentelemetry_Proto_Trace_V1_ScopeSpans.with {
                        $0.spans = spans.map { $0.toProto() }
                    }
                ]
            }

            let exportRequest = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
                $0.resourceSpans = [resourceSpans]
            }

            let body = try exportRequest.serializedData()
            let spanCount = spans.count

            // Fire-and-forget非同期送信
            Task.detached { [weak self] in
                guard let self = self else { return }
                
                do {
                    try await self.sendHTTPRequest(body: body)
                } catch {
                    // エラーハンドリング
                }
            }
        } catch {
            return .failure
        }

        return .success
    }

    private func sendHTTPRequest(body: Data) async throws {
        var request = HTTPClientRequest(url: endpoint.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-protobuf")
        request.headers.add(name: "Content-Length", value: String(body.count))

        // AWS認証情報を取得
        guard let accessKeyId = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"],
              let secretAccessKey = ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] else {
            throw ExportError.missingCredentials
        }

        let sessionToken = ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"]

        // SigV4署名
        let signer = AWSSigV4(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            region: region,
            service: "xray"
        )

        try signer.sign(request: &request, payload: Data(body), date: Date())
        request.body = .bytes(ByteBuffer(data: body))

        let response = try await httpClient.execute(request, timeout: .seconds(30))
        
        if !(200...299).contains(response.status.code) {
            throw ExportError.httpError(statusCode: Int(response.status.code))
        }
    }
}
```

#### OpenTelemetry設定

```swift
enum OpenTelemetryConfiguration {
    static func configureOpenTelemetry(
        serviceName: String, otlpEndpoint: String? = nil, eventLoopGroup: any EventLoopGroup
    ) async throws {
        let environmentName = (try? Environment.detect().name) ?? "development"
        
        let resource = Resource(attributes: [
            "service.name": AttributeValue.string(serviceName),
            "service.version": AttributeValue.string("1.0.0"),
            "deployment.environment": AttributeValue.string(environmentName),
        ])

        // Lambda環境かどうかを確認
        let isLambda = ProcessInfo.processInfo.environment["AWS_LAMBDA_FUNCTION_NAME"] != nil

        let spanExporter: any SpanExporter
        
        if let customEndpoint = otlpEndpoint,
           customEndpoint.starts(with: "https://xray.") && customEndpoint.contains(".amazonaws.com") {
            // X-Ray OTLPエンドポイント
            spanExporter = try await AWSXRayOTLPExporter(
                endpoint: URL(string: customEndpoint)!,
                resource: resource,
                eventLoopGroup: eventLoopGroup
            )
        } else if isLambda {
            // Lambda環境のデフォルト
            spanExporter = try await AWSXRayOTLPExporter(
                resource: resource, 
                eventLoopGroup: eventLoopGroup
            )
        } else {
            // ローカル開発環境
            spanExporter = StdoutSpanExporter(isDebug: true)
        }

        let spanProcessor = BatchSpanProcessor(spanExporter: spanExporter)
        let tracerProvider = TracerProviderBuilder()
            .add(spanProcessor: spanProcessor)
            .with(resource: resource)
            .build()

        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
    }
}
```

#### Vaporミドルウェア

```swift
import OpenTelemetryApi
import Vapor

struct OpenTelemetryTracingMiddleware: AsyncMiddleware {
    let tracer: any Tracer

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // X-Rayトレースコンテキストの伝播
        var traceParent: TraceParent? = nil
        if let xrayTraceId = request.headers.first(name: "x-amzn-trace-id") {
            traceParent = extractXRayTraceContext(from: xrayTraceId)
        }

        let span = tracer.spanBuilder(spanName: "\(request.method.rawValue) \(request.url.path)")
            .setSpanKind(spanKind: .server)
            .setParent(traceParent)
            .setStartTime(time: Date())
            .startSpan()

        // 属性を設定
        span.setAttribute(key: "http.method", value: request.method.rawValue)
        span.setAttribute(key: "http.url", value: request.url.string)
        span.setAttribute(key: "http.target", value: request.url.path)
        span.setAttribute(key: "http.scheme", value: request.url.scheme ?? "http")
        span.setAttribute(key: "net.host.name", value: request.headers.first(name: .host) ?? "")
        span.setAttribute(key: "http.user_agent", value: request.headers.first(name: .userAgent) ?? "")
        
        if let remoteAddress = request.remoteAddress?.description {
            span.setAttribute(key: "net.peer.ip", value: remoteAddress)
        }

        // リクエストを処理
        do {
            let response = try await next.respond(to: request)
            span.setAttribute(key: "http.status_code", value: Int(response.status.code))
            span.end(time: Date())
            return response
        } catch {
            span.setAttribute(key: "http.status_code", value: 500)
            span.setStatus(status: .error(description: error.localizedDescription))
            span.end(time: Date())
            throw error
        }
    }

    private func extractXRayTraceContext(from header: String) -> TraceParent? {
        // X-Ray形式: Root=1-5e1b8b1f-d25b8b1f000000003c8b8b1f;Parent=53995c3f42cd8ad8;Sampled=1
        let components = header.split(separator: ";").reduce(into: [String: String]()) { result, component in
            let parts = component.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            }
        }

        guard let root = components["Root"],
              let parent = components["Parent"] else {
            return nil
        }

        // X-Ray形式のトレースIDをOpenTelemetry形式に変換
        let traceIdParts = root.split(separator: "-")
        guard traceIdParts.count == 3 else { return nil }
        
        let timestamp = String(traceIdParts[1])
        let uniqueId = String(traceIdParts[2])
        let traceIdHex = timestamp + uniqueId

        guard let traceId = TraceId(fromHexString: traceIdHex),
              let spanId = SpanId(fromHexString: parent) else {
            return nil
        }

        let sampled = components["Sampled"] == "1"
        
        return TraceParent(
            traceId: traceId,
            spanId: spanId,
            traceFlags: sampled ? TraceFlags.sampled : TraceFlags()
        )
    }
}
```

#### Vaporアプリケーション設定

```swift
import Vapor

func configure(_ app: Application) async throws {
    // OpenTelemetry設定
    let otlpEndpoint = Environment.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    let serviceName = "CommandServer"  // 固定のサービス名を使用
    
    try await OpenTelemetryConfiguration.configureOpenTelemetry(
        serviceName: serviceName,
        otlpEndpoint: otlpEndpoint,
        eventLoopGroup: app.eventLoopGroup
    )
    
    let tracer = OpenTelemetryConfiguration.getTracer(instrumentationName: "CommandServer")
    
    // ミドルウェア設定
    app.middleware.use(OpenTelemetryTracingMiddleware(tracer: tracer))
    
    // ルート設定など
}
```

## トラブルシューティング

### 1. トレースが表示されない場合

- `aws xray update-trace-segment-destination`が実行されているか確認
- CloudWatch Logsリソースポリシーが正しく設定されているか確認
- Lambda関数のIAMロールに`AWSXRayDaemonWriteAccess`があるか確認
- service.nameが正しく設定されているか確認

### 2. 接続タイムアウトエラー

Lambda環境では初回接続時にタイムアウトが発生することがあります。接続タイムアウトを5秒、読み込みタイムアウトを10秒に設定することで影響を軽減できます。

### 3. デバッグ方法

CloudWatchログでトレース送信の詳細を確認：
```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/YOUR-FUNCTION-NAME \
  --filter-pattern "Exporting OR X-Ray OR TraceID" \
  --start-time $(date -u -d '10 minutes ago' +%s)000
```

X-Ray APIでトレースを検索：
```bash
aws xray get-trace-summaries \
  --region ap-northeast-1 \
  --start-time $(date -u -d '10 minutes ago' +%s) \
  --end-time $(date -u +%s)
```

## まとめ

Swift on LambdaでX-Ray OTLPを使用するには、以下が必要です：

1. X-Ray OTLP APIの有効化（UpdateTraceSegmentDestination）
2. CloudWatch Logsリソースポリシーの設定
3. Lambda関数への適切な環境変数とIAMロールの設定
4. アプリケーション内でのOTLP/HTTP実装とSigV4認証
5. OpenTelemetryの適切な設定とX-Rayトレースコンテキストの伝播

これにより、CloudWatch Application Signalsと統合された詳細なトレーシングが可能になり、Lambda関数の実行環境とアプリケーションのトレースが統合して表示されます。