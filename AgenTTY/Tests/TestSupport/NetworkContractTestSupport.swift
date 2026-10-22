import Foundation
import XCTest
@testable import AgenTTY_iOS

func analyticsJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let encoded = try AgenTTYAnalyticsCodec.makeEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
}

func requestBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while stream.hasBytesAvailable {
        let bytesRead = unsafe stream.read(&buffer, maxLength: bufferSize)
        if bytesRead < 0 {
            return nil
        }
        if bytesRead == 0 {
            break
        }
        data.append(contentsOf: buffer[..<bytesRead])
    }

    return data
}

func jsonObject(from request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(requestBodyData(from: request))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

func makeJSONResponse(
    url: URL,
    statusCode: Int,
    body: Any
) throws -> (HTTPURLResponse, Data) {
    let data = try JSONSerialization.data(withJSONObject: body)
    let response = try XCTUnwrap(
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return (response, data)
}

func makeRequestHandlerURLSession(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [RequestHandlerURLProtocol.self]
    RequestHandlerURLProtocol.setHandler(handler)
    return URLSession(configuration: sessionConfiguration)
}

final class AnalyticsClientTestTransport: @unchecked Sendable {
    typealias Handler = @Sendable (
        URLRequest,
        Data?,
        AnalyticsClientTestTransport
    ) throws -> (HTTPURLResponse, Data)

    private let lock = NSLock()
    private let handler: Handler?
    private var ensureDeviceIdentityCallCountStorage = 0
    private var requestsStorage: [URLRequest] = []
    private var requestBodiesStorage: [Data] = []

    init(handler: Handler? = nil) {
        self.handler = handler
    }

    var ensureDeviceIdentityCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ensureDeviceIdentityCallCountStorage
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    var requestBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return requestBodiesStorage
    }

    func incrementEnsureDeviceIdentityCallCount() {
        lock.lock()
        ensureDeviceIdentityCallCountStorage += 1
        lock.unlock()
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = requestBodyData(from: request)
        lock.lock()
        requestsStorage.append(request)
        if let requestBody = body {
            requestBodiesStorage.append(requestBody)
        }
        lock.unlock()

        if let handler {
            return try handler(request, body, self)
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 204,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data())
    }
}

final class PairingClientTestTransport: @unchecked Sendable {
    typealias Handler = @Sendable (
        URLRequest,
        PairingClientTestTransport
    ) throws -> (HTTPURLResponse, Data)

    private let lock = NSLock()
    private let handler: Handler
    private var claimAttemptCountStorage = 0
    private var ensureDeviceIdentityCallCountStorage = 0
    private var requestsStorage: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var claimAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return claimAttemptCountStorage
    }

    var ensureDeviceIdentityCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ensureDeviceIdentityCallCountStorage
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func incrementClaimAttemptCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        claimAttemptCountStorage += 1
        return claimAttemptCountStorage
    }

    func incrementEnsureDeviceIdentityCallCount() {
        lock.lock()
        ensureDeviceIdentityCallCountStorage += 1
        lock.unlock()
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        requestsStorage.append(request)
        lock.unlock()
        return try handler(request, self)
    }
}

final class AnalyticsClientDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var current: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private final class RequestHandlerURLProtocolStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func currentHandler() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        let handler = handler
        lock.unlock()
        return handler
    }
}

final class RequestHandlerURLProtocol: URLProtocol {
    private static let storage = RequestHandlerURLProtocolStorage()

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        storage.setHandler(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.storage.currentHandler() else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: "RequestHandlerURLProtocol", code: 1)
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
