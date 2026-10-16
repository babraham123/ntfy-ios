import UIKit

/// Opens `ntfy://` links (see `EnrollLink`): signs in with an enrollment code if needed,
/// subscribes to the topic and shows it.
class DeepLinkHandler {
    static let shared = DeepLinkHandler()

    private let tag = "DeepLinkHandler"
    private let store = Store.shared

    /// The user-set device name is hidden since iOS 16 without an entitlement, so the label uses the model
    private var deviceLabel: String {
        return "\(UIDevice.current.model) (ntfy iOS)"
    }

    func handle(_ url: URL, delegate: AppDelegate) {
        Log.d(tag, "Opening link \(url.scheme ?? "?")://\(url.host ?? "?")\(url.path)")
        guard let link = EnrollLink.parse(url) else {
            delegate.deepLinkAlert = DeepLinkAlert(message: "This link is not a valid ntfy topic link.")
            return
        }
        let savedUsername = store.getUser(baseUrl: link.baseUrl)?.username
        switch EnrollLink.decide(link, savedUsername: savedUsername) {
        case .refuse(let reason):
            Log.w(tag, "Refusing link for \(link.baseUrl): \(reason)")
            delegate.deepLinkAlert = DeepLinkAlert(message: reason.message)
        case .subscribe:
            subscribeAndOpen(link, delegate: delegate)
        case .redeem(let code):
            redeemAndSubscribe(link, code: code, delegate: delegate)
        }
    }

    private func redeemAndSubscribe(_ link: EnrollLink, code: String, delegate: AppDelegate) {
        ApiService.shared.redeemToken(baseUrl: link.baseUrl, code: code, label: deviceLabel) { result in
            DispatchQueue.main.async {
                switch result {
                case .Success(let response):
                    guard self.store.saveUser(baseUrl: link.baseUrl, username: response.username, token: response.token) else {
                        delegate.deepLinkAlert = DeepLinkAlert(message: "Could not save user \(response.username) for \(shortUrl(url: link.baseUrl)), because another user is already signed in to this server.")
                        return
                    }
                    self.subscribeAndOpen(link, delegate: delegate)
                case .InvalidCode:
                    delegate.deepLinkAlert = DeepLinkAlert(message: "This sign-in code is invalid, already used or expired. Ask for a new link.")
                case .NotSupported:
                    delegate.deepLinkAlert = DeepLinkAlert(message: "\(shortUrl(url: link.baseUrl)) does not support sign-in codes. The server may need to be upgraded.")
                case .Error(let error):
                    delegate.deepLinkAlert = DeepLinkAlert(message: "Could not sign in to \(shortUrl(url: link.baseUrl)): \(error)")
                }
            }
        }
    }

    private func subscribeAndOpen(_ link: EnrollLink, delegate: AppDelegate) {
        let url = topicUrl(baseUrl: link.baseUrl, topic: link.topic)
        if store.getSubscription(baseUrl: link.baseUrl, topic: link.topic) != nil {
            Log.d(tag, "Already subscribed to \(url), opening topic")
            delegate.selectedBaseUrl = url
            return
        }
        // saveSubscription() saves via DispatchQueue.main.sync, so subscribing on main would deadlock
        DispatchQueue.global(qos: .userInitiated).async {
            SubscriptionManager(store: self.store).subscribe(baseUrl: link.baseUrl, topic: link.topic)
            DispatchQueue.main.async {
                delegate.selectedBaseUrl = url
            }
        }
    }
}

struct DeepLinkAlert: Identifiable {
    let id = UUID()
    var title = "Cannot open link"
    let message: String
}
