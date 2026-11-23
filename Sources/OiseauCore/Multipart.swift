import Foundation

/// A `multipart/form-data` body — how finds, reports, placements and avatars travel
/// with their photo (Android: OkHttp's MultipartBody, `ApiClient.postForm`).
public struct MultipartForm: Sendable {
    public struct Part: Sendable, Equatable {
        public var name: String
        public var filename: String?
        public var contentType: String?
        public var data: Data
    }

    public private(set) var parts: [Part] = []
    public let boundary: String

    public init(boundary: String = "oiseau-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// A text field.
    public mutating func add(_ name: String, _ value: String) {
        parts.append(Part(name: name, filename: nil, contentType: nil, data: Data(value.utf8)))
    }

    /// A file field (a JPEG photo).
    public mutating func add(_ name: String, filename: String, contentType: String = "image/jpeg", data: Data) {
        parts.append(Part(name: name, filename: filename, contentType: contentType, data: data))
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// RFC 7578: each part opened by `--boundary`, its headers, a blank line, the bytes; closed by `--boundary--`.
    public func encoded() -> Data {
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        for p in parts {
            line("--\(boundary)")
            var disposition = "Content-Disposition: form-data; name=\"\(escape(p.name))\""
            if let filename = p.filename { disposition += "; filename=\"\(escape(filename))\"" }
            line(disposition)
            if let type = p.contentType { line("Content-Type: \(type)") }
            line("")
            body.append(p.data)
            line("")
        }
        line("--\(boundary)--")
        return body
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
    }

    /// The text fields of a body (files: their filename), by name — for the stub server.
    public static func fields(of body: Data, contentType: String?) -> [String: String] {
        guard let contentType, let range = contentType.range(of: "boundary=") else { return [:] }
        let boundary = String(contentType[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let text = String(decoding: body, as: UTF8.self)
        var out: [String: String] = [:]
        for chunk in text.components(separatedBy: "--\(boundary)") {
            guard let headerEnd = chunk.range(of: "\r\n\r\n") else { continue }
            let headers = String(chunk[..<headerEnd.lowerBound])
            guard let name = attribute("name", in: headers) else { continue }
            if let filename = attribute("filename", in: headers) {
                out[name] = filename
            } else {
                var value = String(chunk[headerEnd.upperBound...])
                // "\r\n" is one Character in Swift: drop its two scalars.
                if value.hasSuffix("\r\n") { value = String(value.unicodeScalars.dropLast(2)) }
                out[name] = value
            }
        }
        return out
    }

    private static func attribute(_ key: String, in headers: String) -> String? {
        guard let start = headers.range(of: " \(key)=\"") else { return nil }
        let rest = headers[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

public extension ApiClient {
    /// A multipart POST (Android: `postForm`). [timeout]: for the gestures that are
    /// parked rather than waited on ([ApiClient.gestureTimeout]).
    func postForm<T: Decodable>(_ path: String, _ form: MultipartForm, as type: T.Type = T.self, timeout: TimeInterval? = nil) async throws(ApiError) -> T? {
        let data = try await send("POST", path, body: form.encoded(), contentType: form.contentType, timeout: timeout)
        guard let data else { return nil }
        do {
            return try ApiJson.decoder.decode(T.self, from: data)
        } catch {
            throw ApiError(status: 200, code: "bad_response", message: "\(error)")
        }
    }

    /// A PATCH of a raw JSON object (a body that must say `null`).
    func patch(_ path: String, json: JsonObject) async throws(ApiError) {
        _ = try await send("PATCH", path, body: json.jsonData(), contentType: "application/json")
    }
}
