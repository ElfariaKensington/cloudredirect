import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

// Same public desktop OAuth application registrations as upstream CloudRedirect.
struct OAuth {
    struct Registration { let client: String; let secret: String; let scope: String; let auth: String; let token: String }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError.message("Could not generate OAuth state.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func form(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
    }
    static func authorize(_ provider: String) async throws -> Data {
        let registration = registrations[provider]!
        let state = try random(), verifier = try random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw AppError.message("Could not open OAuth callback listener.") }
        defer { close(socketFD) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(provider == "onedrive" ? 53682 : 0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(socketFD, 4) == 0 else { throw AppError.message("OAuth callback port is busy. Close other sign-in windows and try again.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        let redirect = "http://localhost:\(UInt16(bigEndian: address.sin_port))/"
        var parameters = ["client_id": registration.client, "redirect_uri": redirect, "response_type": "code", "scope": registration.scope, "state": state, "code_challenge": challenge, "code_challenge_method": "S256"]
        if provider == "gdrive" { parameters["access_type"] = "offline"; parameters["prompt"] = "consent" }
        let url = URL(string: registration.auth + "?" + form(parameters))!
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw AppError.message("Could not open your browser.") }
        let code = try await Task.detached { () throws -> String in
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 1000) > 0 else { continue }
                let client = accept(socketFD, nil, nil); if client < 0 { continue }
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var bytes = [UInt8](repeating: 0, count: 16384); var request = Data()
                while request.count < bytes.count {
                    let count = recv(client, &bytes, bytes.count - request.count, 0)
                    if count <= 0 { break }; request.append(contentsOf: bytes.prefix(count))
                    if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
                }
                let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                let components = parts.count == 3 && parts[0] == "GET" ? URLComponents(string: "http://localhost" + parts[1]) : nil
                let values = components?.queryItems ?? []
                let validState = values.first(where: { $0.name == "state" })?.value == state
                let code = values.first(where: { $0.name == "code" })?.value
                let valid = validState && code != nil
                let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n\(valid ? "Signed in. Return to CloudRedirect." : "Invalid callback. Return to your sign-in window.")"
                var noSignal: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, 4)
                _ = response.withCString { send(client, $0, strlen($0), 0) }; close(client)
                if valid { return code! }
                if validState && values.contains(where: { $0.name == "error" }) { throw AppError.message("Sign-in was declined.") }
            }
            throw AppError.message("Sign-in timed out. Try again.")
        }.value
        var body = ["client_id": registration.client, "client_secret": registration.secret, "code": code, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier]
        if provider == "onedrive" { body["scope"] = registration.scope }
        var request = URLRequest(url: URL(string: registration.token)!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(body).utf8); request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              var tokens = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else { throw AppError.message("The provider did not issue a refresh token. Retry sign-in and grant access.") }
        tokens["expires_at"] = Int(Date().timeIntervalSince1970) + (tokens["expires_in"] as? Int ?? 3600)
        return try JSONSerialization.data(withJSONObject: tokens)
    }
    static let registrations: [String: Registration] = [
        "gdrive": Registration(client: "1072944905499-vm2v2i5dvn0a0d2o4ca36i1vge8cvbn0.apps.googleusercontent.com", secret: "v6V3fKV_zWU7iw1DrpO1rknX", scope: "https://www.googleapis.com/auth/drive.file", auth: "https://accounts.google.com/o/oauth2/v2/auth", token: "https://oauth2.googleapis.com/token"),
        "onedrive": Registration(client: "b15665d9-eda6-4092-8539-0eec376afd59", secret: "qtyfaBBYA403=unZUP40~_#", scope: "Files.ReadWrite offline_access", auth: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", token: "https://login.microsoftonline.com/common/oauth2/v2.0/token"),
    ]
}
