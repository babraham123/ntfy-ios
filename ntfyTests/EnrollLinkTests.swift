import XCTest
@testable import ntfy

final class EnrollLinkTests: XCTestCase {
    private func link(_ string: String) -> EnrollLink? {
        return EnrollLink.parse(URL(string: string)!)
    }

    // MARK: Parsing

    func testParsesHostTopicUserAndCode() {
        XCTAssertEqual(
            link("ntfy://ntfy.example.com/alerts?user=phil&code=abc123"),
            EnrollLink(baseUrl: "https://ntfy.example.com", topic: "alerts", user: "phil", code: "abc123", secure: true)
        )
    }

    func testParsesPortAndInsecureFlag() {
        XCTAssertEqual(
            link("ntfy://10.0.0.2:8080/alerts?secure=false"),
            EnrollLink(baseUrl: "http://10.0.0.2:8080", topic: "alerts", user: nil, code: nil, secure: false)
        )
    }

    func testSecureFlagOtherThanFalseMeansHttps() {
        XCTAssertEqual(link("ntfy://ntfy.sh/alerts?secure=true")?.baseUrl, "https://ntfy.sh")
        XCTAssertEqual(link("ntfy://ntfy.sh/alerts?secure=no")?.baseUrl, "https://ntfy.sh")
    }

    func testEmptyParametersAreAbsent() {
        let parsed = link("ntfy://ntfy.sh/alerts?user=&code=")
        XCTAssertNil(parsed?.user)
        XCTAssertNil(parsed?.code)
    }

    func testIgnoresDisplayParameter() {
        XCTAssertEqual(link("ntfy://ntfy.sh/alerts?display=My%20Alerts")?.topic, "alerts")
    }

    func testAllowsTrailingSlash() {
        XCTAssertEqual(link("ntfy://ntfy.sh/alerts/")?.topic, "alerts")
    }

    func testRejectsInvalidLinks() {
        XCTAssertNil(link("https://ntfy.sh/alerts"), "wrong scheme")
        XCTAssertNil(link("ntfy://ntfy.sh/"), "no topic")
        XCTAssertNil(link("ntfy://ntfy.sh/a/b"), "nested path")
        XCTAssertNil(link("ntfy://ntfy.sh/bad%20topic"), "invalid topic characters")
        XCTAssertNil(link("ntfy://ntfy.sh/\(String(repeating: "a", count: 65))"), "topic too long")
        XCTAssertNil(link("ntfy:///alerts"), "no host")
    }

    // MARK: Decision table

    func testCodeWithInsecureConnectionIsRefused() {
        let insecure = link("ntfy://10.0.0.2/alerts?user=phil&code=abc&secure=false")!
        XCTAssertEqual(EnrollLink.decide(insecure, savedUsername: nil), .refuse(.insecureCode))
        XCTAssertEqual(EnrollLink.decide(insecure, savedUsername: "phil"), .refuse(.insecureCode))
    }

    func testInsecureLinkWithoutCodeSubscribes() {
        let insecure = link("ntfy://10.0.0.2/alerts?secure=false")!
        XCTAssertEqual(EnrollLink.decide(insecure, savedUsername: nil), .subscribe)
    }

    func testNoSavedUserWithCodeRedeems() {
        XCTAssertEqual(EnrollLink.decide(link("ntfy://ntfy.sh/alerts?user=phil&code=abc")!, savedUsername: nil), .redeem(code: "abc"))
        XCTAssertEqual(EnrollLink.decide(link("ntfy://ntfy.sh/alerts?code=abc")!, savedUsername: nil), .redeem(code: "abc"))
    }

    func testNoSavedUserWithoutCodeSubscribes() {
        XCTAssertEqual(EnrollLink.decide(link("ntfy://ntfy.sh/alerts")!, savedUsername: nil), .subscribe)
        XCTAssertEqual(EnrollLink.decide(link("ntfy://ntfy.sh/alerts?user=phil")!, savedUsername: nil), .subscribe)
    }

    func testMatchingSavedUserSubscribesAndIgnoresCode() {
        XCTAssertEqual(EnrollLink.decide(link("ntfy://ntfy.sh/alerts?user=phil&code=abc")!, savedUsername: "phil"), .subscribe)
        XCTAssertEqual(EnrollLink.decide(link("ntfy://ntfy.sh/alerts?user=phil")!, savedUsername: "phil"), .subscribe)
    }

    func testSavedUserAndLinkWithoutUserSubscribesAndIgnoresCode() {
        XCTAssertEqual(EnrollLink.decide(link("ntfy://ntfy.sh/alerts?code=abc")!, savedUsername: "phil"), .subscribe)
        XCTAssertEqual(EnrollLink.decide(link("ntfy://ntfy.sh/alerts")!, savedUsername: "phil"), .subscribe)
    }

    func testDifferentSavedUserIsRefused() {
        XCTAssertEqual(
            EnrollLink.decide(link("ntfy://ntfy.sh/alerts?user=alice&code=abc")!, savedUsername: "phil"),
            .refuse(.differentUser(saved: "phil", link: "alice"))
        )
        XCTAssertEqual(
            EnrollLink.decide(link("ntfy://ntfy.sh/alerts?user=alice")!, savedUsername: "phil"),
            .refuse(.differentUser(saved: "phil", link: "alice"))
        )
    }

    // MARK: Credentials

    func testTokenCredentialSendsBearerHeader() {
        XCTAssertEqual(UserCredential(username: "phil", password: "", token: "tk_abc").toHeader(), "Bearer tk_abc")
    }

    func testPasswordCredentialSendsBasicHeader() {
        XCTAssertEqual(UserCredential(username: "phil", password: "secret").toHeader(), "Basic cGhpbDpzZWNyZXQ=")
    }
}
