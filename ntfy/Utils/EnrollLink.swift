import Foundation

/// A `ntfy://<host>[:port]/<topic>?user=<u>&code=<c>[&secure=false]` link. It subscribes to a topic and,
/// with a `code`, signs the device in by redeeming a single-use enrollment code for an access token.
/// The rules match the web app's `/account/token/redeem` page and the Android app.
struct EnrollLink: Equatable {
    static let scheme = "ntfy"
    private static let topicRegex = "^[-_A-Za-z0-9]{1,64}$"

    let baseUrl: String
    let topic: String
    let user: String?
    let code: String?
    let secure: Bool

    static func parse(_ url: URL) -> EnrollLink? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme,
            let host = components.host, !host.isEmpty
        else {
            return nil
        }
        let topic = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard topic.range(of: topicRegex, options: .regularExpression) != nil else {
            return nil
        }
        let query = components.queryItems ?? []
        func param(_ name: String) -> String? {
            guard let value = query.first(where: { $0.name == name })?.value, !value.isEmpty else {
                return nil
            }
            return value
        }
        let secure = param("secure") != "false"
        let port = components.port.map { ":\($0)" } ?? ""
        return EnrollLink(
            baseUrl: normalizeBaseUrl("\(secure ? "https" : "http")://\(host)\(port)"),
            topic: topic,
            user: param("user"),
            code: param("code"),
            secure: secure
        )
    }

    /// Decides what to do with a link, given the username saved for the link's server (if any).
    /// Subscribing to an already subscribed topic is the caller's concern.
    static func decide(_ link: EnrollLink, savedUsername: String?) -> EnrollDecision {
        if link.code != nil && !link.secure {
            return .refuse(.insecureCode)
        }
        if let savedUsername {
            // The code is ignored and expires unused; a saved login is never replaced
            if let user = link.user, user != savedUsername {
                return .refuse(.differentUser(saved: savedUsername, link: user))
            }
            return .subscribe
        }
        if let code = link.code {
            return .redeem(code: code)
        }
        return .subscribe
    }
}

enum EnrollDecision: Equatable {
    case redeem(code: String)
    case subscribe
    case refuse(EnrollRefusal)
}

enum EnrollRefusal: Equatable {
    case insecureCode
    case differentUser(saved: String, link: String)

    var message: String {
        switch self {
        case .insecureCode:
            return "This link contains a sign-in code, but uses an insecure connection (secure=false). Sign-in codes are only sent over HTTPS."
        case .differentUser(let saved, let link):
            return "This link is for user \(link), but you are already signed in to this server as \(saved). Remove that user in Settings first to use this link."
        }
    }
}
