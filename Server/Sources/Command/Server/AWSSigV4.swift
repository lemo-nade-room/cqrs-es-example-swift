import AsyncHTTPClient
import Crypto
import Foundation
import NIOHTTP1

/// 最小限のAWS SigV4署名実装
struct AWSSigV4 {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let region: String
    let service: String

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// HTTPリクエストにSigV4署名を追加
    func sign(request: inout HTTPClientRequest, payload: Data, date: Date = Date()) throws {
        let amzDate = dateFormatter.string(from: date)
        let shortDate = shortDateFormatter.string(from: date)

        // 必須ヘッダーを追加
        request.headers.add(name: "X-Amz-Date", value: amzDate)
        if let sessionToken = sessionToken {
            request.headers.add(name: "X-Amz-Security-Token", value: sessionToken)
        }

        // ペイロードのハッシュを計算
        let payloadHash = SHA256.hash(data: payload).hexString()
        request.headers.add(name: "X-Amz-Content-SHA256", value: payloadHash)

        // 正規リクエストを作成
        let canonicalRequest = createCanonicalRequest(
            method: request.method.rawValue,
            uri: request.url,
            headers: request.headers,
            payloadHash: payloadHash
        )

        // 署名対象文字列を作成
        let credentialScope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let stringToSign = createStringToSign(
            date: amzDate,
            credentialScope: credentialScope,
            canonicalRequest: canonicalRequest
        )

        // 署名を計算
        let signature = calculateSignature(
            stringToSign: stringToSign,
            shortDate: shortDate
        )

        // Authorizationヘッダーを作成
        let signedHeaders = getSignedHeaders(from: request.headers)
        let authorizationHeader = "AWS4-HMAC-SHA256 " +
            "Credential=\(accessKeyId)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), " +
            "Signature=\(signature)"

        request.headers.add(name: "Authorization", value: authorizationHeader)
    }

    private func createCanonicalRequest(
        method: String,
        uri: String,
        headers: HTTPHeaders,
        payloadHash: String
    ) -> String {
        // URIパスを正規化
        let path = URL(string: uri)?.path ?? "/"
        let canonicalURI = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        )?.replacingOccurrences(of: "%2F", with: "/") ?? "/"

        // クエリ文字列を正規化
        let canonicalQueryString = URL(string: uri)?.query?
            .split(separator: "&")
            .map { String($0) }
            .sorted()
            .joined(separator: "&") ?? ""

        // ヘッダーを正規化
        let canonicalHeaders = headers
            .map {
                (
                    name: $0.name.lowercased(),
                    value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .sorted { $0.name < $1.name }
            .map { "\($0.name):\($0.value)" }
            .joined(separator: "\n")

        // 署名済みヘッダー
        let signedHeaders = getSignedHeaders(from: headers)

        return [
            method,
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders + "\n",
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
    }

    private func getSignedHeaders(from headers: HTTPHeaders) -> String {
        return headers
            .map { $0.name.lowercased() }
            .sorted()
            .joined(separator: ";")
    }

    private func createStringToSign(
        date: String,
        credentialScope: String,
        canonicalRequest: String
    ) -> String {
        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString()

        return [
            "AWS4-HMAC-SHA256",
            date,
            credentialScope,
            canonicalRequestHash,
        ].joined(separator: "\n")
    }

    private func calculateSignature(
        stringToSign: String,
        shortDate: String
    ) -> String {
        let kSecret = "AWS4" + secretAccessKey
        let kDate = HMAC<SHA256>.authenticationCode(
            for: Data(shortDate.utf8),
            using: SymmetricKey(data: Data(kSecret.utf8))
        )
        let kRegion = HMAC<SHA256>.authenticationCode(
            for: Data(region.utf8),
            using: SymmetricKey(data: kDate)
        )
        let kService = HMAC<SHA256>.authenticationCode(
            for: Data(service.utf8),
            using: SymmetricKey(data: kRegion)
        )
        let kSigning = HMAC<SHA256>.authenticationCode(
            for: Data("aws4_request".utf8),
            using: SymmetricKey(data: kService)
        )

        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: kSigning)
        )

        return signature.hexString()
    }
}

extension Sequence where Element == UInt8 {
    func hexString() -> String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}