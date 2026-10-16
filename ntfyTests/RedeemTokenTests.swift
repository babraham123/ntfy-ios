import XCTest
@testable import ntfy

final class RedeemTokenTests: XCTestCase {
    private let api = ApiService(protocolClasses: [StubURLProtocol.self])

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func redeem(code: String = "abc123", label: String = "iPhone (ntfy iOS)") -> RedeemResult {
        let done = expectation(description: "redeem")
        var result: RedeemResult?
        api.redeemToken(baseUrl: "https://ntfy.example.com/", code: code, label: label) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result!
    }

    func testSendsUnauthenticatedJsonPost() throws {
        StubURLProtocol.respond(status: 200, body: #"{"token":"tk_abc","username":"phil","label":"iPhone (ntfy iOS)","last_access":0,"last_origin":"","expires":0}"#)
        _ = redeem(code: "abc123", label: "iPhone (ntfy iOS)")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.example.com/v1/account/token/redeem")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastBody)) as? [String: String])
        XCTAssertEqual(body, ["code": "abc123", "label": "iPhone (ntfy iOS)"])
    }

    func testSuccessReturnsTokenAndUsername() {
        StubURLProtocol.respond(status: 200, body: #"{"token":"tk_abc","username":"phil","label":"Enrolled device","last_access":0,"last_origin":"","expires":0}"#)
        guard case .Success(let response) = redeem() else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(response.token, "tk_abc")
        XCTAssertEqual(response.username, "phil")
    }

    func testInvalidUsedOrExpiredCode() {
        StubURLProtocol.respond(status: 400, body: #"{"code":40060,"http":400,"error":"invalid request: enrollment code invalid or expired"}"#)
        guard case .InvalidCode = redeem() else {
            return XCTFail("expected invalid code")
        }
    }

    func testServerWithoutEnrollmentSupport() {
        StubURLProtocol.respond(status: 404, body: #"{"code":40401,"http":404,"error":"page not found"}"#)
        guard case .NotSupported = redeem() else {
            return XCTFail("expected not supported")
        }
    }

    func testOtherErrorsSurfaceServerMessage() {
        StubURLProtocol.respond(status: 429, body: #"{"code":42901,"http":429,"error":"limit reached: too many requests"}"#)
        guard case .Error(let message) = redeem() else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(message, "limit reached: too many requests")
    }

    func testSuccessWithoutTokenIsAnError() {
        StubURLProtocol.respond(status: 200, body: #"<html>not ntfy</html>"#)
        guard case .Error = redeem() else {
            return XCTFail("expected error")
        }
    }
}

/// Serves a canned response and records the request it received.
final class StubURLProtocol: URLProtocol {
    private static var status = 200
    private static var body = Data()
    private(set) static var lastRequest: URLRequest?
    private(set) static var lastBody: Data?

    static func respond(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    static func reset() {
        status = 200
        body = Data()
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLSession moves POST bodies into a stream before they reach a URLProtocol
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
