import Foundation

extension User {
    var isTokenUser: Bool {
        return token?.isEmpty == false
    }

    func toCredential() -> UserCredential {
        return UserCredential(username: username ?? "?", password: password ?? "?", token: token)
    }
}
