import Foundation

/// A provider that is not there: every request a test's session makes lands in
/// ``handler``, which answers it — at once, or later, a piece at a time.
///
/// A `URLProtocol` rather than a server on a port. What is under test is what
/// the chat does with a provider's answers, and a socket would add a port to
/// collide on and nothing to the question.
final class FakeProvider: URLProtocol {

	/// One request being answered.
	final class Reply: @unchecked Sendable {
		private let owner: URLProtocol
		private var opened = false
		init(_ owner: URLProtocol) { self.owner = owner }

		func open(status: Int = 200, type: String = "application/json") {
			guard !opened, let url = owner.request.url else { return }
			opened = true
			let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
			                               headerFields: ["Content-Type": type])!
			owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
		}

		func send(_ text: String) {
			open()
			owner.client?.urlProtocol(owner, didLoad: Data(text.utf8))
		}

		func finish() {
			open()
			owner.client?.urlProtocolDidFinishLoading(owner)
		}

		/// The whole answer at once.
		func json(_ text: String, status: Int = 200) {
			open(status: status)
			send(text)
			finish()
		}

		/// A server-sent stream of `data:` lines, ended.
		func events(_ payloads: [String]) {
			open(type: "text/event-stream")
			for payload in payloads { send("data: \(payload)\n\n") }
			finish()
		}
	}

	/// One test's provider: an address nobody else has, what to answer there,
	/// and what was asked.
	///
	/// Its own address rather than one handler for everybody, because tests run
	/// side by side and a shared handler would have one test answering
	/// another's requests.
	final class Stage: @unchecked Sendable {
		let host = "\(UUID().uuidString.lowercased()).test"
		var root: URL { URL(string: "http://\(host)")! }

		private let lock = NSLock()
		private var answer: ((_ path: String, _ body: [String: Any], Reply) -> Void)?
		private var asked: [(path: String, body: [String: Any], token: String?)] = []

		var handler: ((_ path: String, _ body: [String: Any], Reply) -> Void)? {
			get { lock.withLock { answer } }
			set { lock.withLock { answer = newValue } }
		}

		var seen: [(path: String, body: [String: Any], token: String?)] { lock.withLock { asked } }

		fileprivate func note(_ path: String, _ body: [String: Any], _ token: String?) {
			lock.withLock { asked.append((path, body, token)) }
		}

		init() { FakeProvider.lock.withLock { FakeProvider.stages[host] = self } }
		deinit { FakeProvider.lock.withLock { _ = FakeProvider.stages.removeValue(forKey: host) } }

		func session() -> URLSession {
			let configuration = URLSessionConfiguration.ephemeral
			configuration.protocolClasses = [FakeProvider.self]
			return URLSession(configuration: configuration)
		}
	}

	private static let lock = NSLock()
	nonisolated(unsafe) private static var stages: [String: Stage] = [:]

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		// A request handed to a protocol has lost its body to a stream.
		var data = request.httpBody ?? Data()
		if let stream = request.httpBodyStream {
			stream.open()
			var buffer = [UInt8](repeating: 0, count: 65_536)
			while stream.hasBytesAvailable {
				let read = stream.read(&buffer, maxLength: buffer.count)
				guard read > 0 else { break }
				data.append(buffer, count: read)
			}
			stream.close()
		}
		let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
		let path = request.url?.path ?? ""
		let stage = Self.lock.withLock { Self.stages[request.url?.host ?? ""] }
		stage?.note(path, body, request.value(forHTTPHeaderField: "Authorization"))
		guard let handler = stage?.handler else {
			Reply(self).json(#"{"error":"nobody is playing this provider"}"#, status: 500)
			return
		}
		handler(path, body, Reply(self))
	}

	override func stopLoading() {}
}
