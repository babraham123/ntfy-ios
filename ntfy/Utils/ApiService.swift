import Foundation

class ApiService {
    static let shared = ApiService()
    static let userAgent = "ntfy/\(Config.version) (build \(Config.build); iOS \(Config.osVersion))"
    
    private let tag = "ApiService"
    private let protocolClasses: [AnyClass]

    /// `protocolClasses` lets tests stub the network; sessions with a custom configuration
    /// ignore `URLProtocol.registerClass`.
    init(protocolClasses: [AnyClass] = []) {
        self.protocolClasses = protocolClasses
    }
    
    func poll(subscription: Subscription, user: UserCredential?, completionHandler: @escaping ([Message]?, Error?) -> Void) {
        guard let url = URL(string: subscription.urlString()) else {
            completionHandler(nil, URLError(.badURL))
            return
        }
        let since = subscription.lastNotificationId ?? "all"
        let urlString = "\(url)/json?poll=1&since=\(since)"
        
        Log.d(tag, "Polling from \(urlString) with user \(user?.username ?? "anonymous")")
        fetchJsonData(urlString: urlString, user: user, completionHandler: completionHandler)
    }
    
    func poll(subscription: Subscription, messageId: String, user: UserCredential?, completionHandler: @escaping (Message?, Error?) -> Void) {
        poll(baseUrl: subscription.baseUrl ?? "?", topic: subscription.topic ?? "?", messageId: messageId, user: user, completionHandler: completionHandler)
    }

    func poll(baseUrl: String, topic: String, messageId: String, user: UserCredential?, completionHandler: @escaping (Message?, Error?) -> Void) {
        guard let url = URL(string: "\(topicUrl(baseUrl: baseUrl, topic: topic))/json?poll=1&id=\(messageId)") else {
            completionHandler(nil, URLError(.badURL))
            return
        }
        Log.d(tag, "Polling single message from \(url) with user \(user?.username ?? "anonymous")")
        
        let request = newRequest(url: url, user: user)
        newSession(timeout: 30).dataTask(with: request) { (data, response, error) in
            if let error = error {
                completionHandler(nil, error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                completionHandler(nil, URLError(.badServerResponse))
                return
            }
            guard let data = data else {
                completionHandler(nil, URLError(.badServerResponse))
                return
            }
            do {
                let message = try JSONDecoder().decode(Message.self, from: data)
                completionHandler(message, nil)
            } catch {
                completionHandler(nil, error)
            }
        }.resume()
    }

    func publish(
        subscription: Subscription,
        user: UserCredential?,
        message: String,
        title: String,
        priority: Int = 3,
        tags: [String] = [],
        completionHandler: (() -> Void)? = nil
    ) {
        guard let url = URL(string: subscription.urlString()) else { return }
        var request = newRequest(url: url, user: user)

        Log.d(tag, "Publishing to \(url)")
        
        request.httpMethod = "POST"
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(String(priority), forHTTPHeaderField: "Priority")
        request.setValue(tags.joined(separator: ","), forHTTPHeaderField: "Tags")
        request.httpBody = message.data(using: String.Encoding.utf8)
        newSession(timeout: 10).dataTask(with: request) { (data, response, error) in
            guard error == nil else {
                Log.e(self.tag, "Error publishing message", error!)
                return
            }
            Log.d(self.tag, "Publishing message succeeded", response)
            completionHandler?()
        }.resume()
    }
    
    func checkAuth(baseUrl: String, topic: String, user: UserCredential?, completionHandler: @escaping(AuthResult) -> Void) {
        guard let url = URL(string: topicAuthUrl(baseUrl: baseUrl, topic: topic)) else { return }
        let request = newRequest(url: url, user: user)
        Log.d(tag, "Checking auth for \(url) with user \(user?.username ?? "anonymous")")
        newSession(timeout: 10).dataTask(with: request) { (data, response, error) in
            if let error = error {
                Log.e(self.tag, "Error checking auth: \(error)")
                completionHandler(.Error(error.localizedDescription))
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    completionHandler(.Unauthorized)
                } else {
                    completionHandler(.Error("Unexpected response from server: \(httpResponse.statusCode)"))
                }
            } else if let data = data {
                do {
                    let result = try JSONDecoder().decode(AuthCheckResponse.self, from: data)
                    Log.d(self.tag, "Auth result: \(result)")
                    if result.success == true {
                        completionHandler(.Success)
                    } else {
                        completionHandler(.Error("Unexpected response from server"))
                    }
                } catch {
                    Log.e(self.tag, "Error handling auth response: \(error)")
                    completionHandler(.Error("Unexpected response from server. Is this a ntfy server?"))
                }
            }
        }.resume()
    }

    /// Exchanges a single-use enrollment code for an access token. The request is unauthenticated,
    /// since the code itself is the credential.
    func redeemToken(baseUrl: String, code: String, label: String, completionHandler: @escaping (RedeemResult) -> Void) {
        guard let url = URL(string: tokenRedeemUrl(baseUrl: baseUrl)) else {
            completionHandler(.Error("Invalid server URL"))
            return
        }
        var request = newRequest(url: url, user: nil)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RedeemTokenRequest(code: code, label: label))
        Log.d(tag, "Redeeming enrollment code at \(url)")
        newSession(timeout: 10).dataTask(with: request) { (data, response, error) in
            if let error = error {
                Log.e(self.tag, "Error redeeming enrollment code", error)
                completionHandler(.Error(error.localizedDescription))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completionHandler(.Error("Unexpected response from server"))
                return
            }
            switch httpResponse.statusCode {
            case 200:
                guard let data, let result = try? JSONDecoder().decode(RedeemTokenResponse.self, from: data), !result.token.isEmpty, !result.username.isEmpty else {
                    completionHandler(.Error("Unexpected response from server. Is this a ntfy server?"))
                    return
                }
                Log.d(self.tag, "Enrollment code redeemed for user \(result.username)")
                completionHandler(.Success(result))
            case 404:
                completionHandler(.NotSupported)
            default:
                let errorResponse = data.flatMap { try? JSONDecoder().decode(AuthCheckResponse.self, from: $0) }
                if errorResponse?.code == RedeemTokenResponse.errorCodeInvalidCode {
                    completionHandler(.InvalidCode)
                } else if let message = errorResponse?.error, !message.isEmpty {
                    completionHandler(.Error(message))
                } else {
                    completionHandler(.Error("Unexpected response from server: \(httpResponse.statusCode)"))
                }
            }
        }.resume()
    }

    private func fetchJsonData<T: Decodable>(urlString: String, user: UserCredential?, completionHandler: @escaping ([T]?, Error?) -> ()) {
        guard let url = URL(string: urlString) else {
            completionHandler(nil, URLError(.badURL))
            return
        }
        let request = newRequest(url: url, user: user)
        newSession(timeout: 30).dataTask(with: request) { (data, response, error) in
            if let error {
                Log.e(self.tag, "Error fetching data", error)
                completionHandler(nil, error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                completionHandler(nil, URLError(.badServerResponse))
                return
            }
            guard let data = data else {
                completionHandler(nil, URLError(.badServerResponse))
                return
            }
            do {
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                var notifications: [T] = []
                for jsonLine in lines {
                    guard let jsonData = jsonLine.data(using: .utf8) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    notifications.append(try JSONDecoder().decode(T.self, from: jsonData))
                }
                completionHandler(notifications, nil)
            } catch {
                Log.e(self.tag, "Error fetching data", error)
                completionHandler(nil, error)
            }
        }.resume()
    }
    
    private func newRequest(url: URL, user: UserCredential?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        if let user = user {
            request.setValue(user.toHeader(), forHTTPHeaderField: "Authorization")
        }
        return request
    }
    
    private func newSession(timeout: TimeInterval) -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        if !protocolClasses.isEmpty {
            sessionConfig.protocolClasses = protocolClasses + (sessionConfig.protocolClasses ?? [])
        }
        return URLSession(configuration: sessionConfig)
    }
}

/// Credentials for a server: either a username/password pair or an access token.
/// `username` is always the account name, so it can be shown and compared even for token users.
struct UserCredential {
    let username: String
    let password: String
    var token: String? = nil
    
    func toHeader() -> String {
        if let token, !token.isEmpty {
            return "Bearer \(token)"
        }
        return "Basic " + String(format: "%@:%@", username, password).data(using: String.Encoding.utf8)!.base64EncodedString()
    }
}

enum AuthResult {
    case Success
    case Unauthorized
    case Error(String)
}

enum RedeemResult {
    case Success(RedeemTokenResponse)
    case InvalidCode
    case NotSupported
    case Error(String)
}

struct RedeemTokenRequest: Encodable {
    let code: String
    let label: String
}

struct RedeemTokenResponse: Decodable {
    /// Server error code for an invalid, already used or expired enrollment code
    static let errorCodeInvalidCode = 40060

    let token: String
    let username: String
    let label: String?
    let expires: Int64?
}

struct AuthCheckResponse: Codable {
    let success: Bool?
    let code: Int?
    let http: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, code, http, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        self.http = try container.decodeIfPresent(Int.self, forKey: .http)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}
