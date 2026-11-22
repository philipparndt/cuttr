import Foundation

/// A JSON object, as `JSONSerialization` hands it over.
public typealias JSONObject = [String: Any]

enum JSON {
	static func object(_ text: String) -> JSONObject? {
		guard let data = text.data(using: .utf8) else { return nil }
		return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
	}

	static func text(_ value: Any, pretty: Bool = false) -> String {
		var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
		if pretty { options.insert(.prettyPrinted) }
		guard JSONSerialization.isValidJSONObject(value),
		      let data = try? JSONSerialization.data(withJSONObject: value, options: options)
		else { return "{}" }
		return String(decoding: data, as: UTF8.self)
	}
}

/// One model a provider offers.
public struct ModelInfo: Equatable, Sendable {
	public var id: String
	/// The computers that offer it, when the provider says.
	public var workers: [String]

	public init(id: String, workers: [String] = []) {
		self.id = id
		self.workers = workers
	}

	/// Claude Code. An agent rather than a model: it does not return tool calls
	/// to be run for it, it runs a tool loop of its own and reaches the app
	/// through the app's MCP server.
	public var isAgent: Bool { id.hasPrefix("claude-code/") }

	/// "Claude Code (Sonnet)", or the id as it is.
	public var label: String {
		guard isAgent else { return id }
		let model = id.dropFirst("claude-code/".count)
		return "Claude Code (\(model.prefix(1).uppercased())\(model.dropFirst()))"
	}
}

public enum ChatAPI {

	/// Ids in an OpenAI-style list that are not something to chat with. A
	/// provider that says what kind each model is gets asked instead; this is
	/// for the ones that only give names.
	private static let notChat = [
		"embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "realtime",
		"gpt-image", "sora", "davinci", "babbage",
	]

	/// The chat models in a `GET …/models` answer, agents first.
	///
	/// ai-connector says `kind` and `workers`; OpenAI, OpenRouter, LM Studio and
	/// vLLM give `data` with ids; Ollama's own list is `models`.
	public static func models(in body: String) -> [ModelInfo] {
		let root = JSON.object(body)
		let list = (root?["data"] as? [JSONObject]) ?? (root?["models"] as? [JSONObject]) ?? []
		var out: [ModelInfo] = []
		for entry in list {
			guard let id = (entry["id"] as? String) ?? (entry["model"] as? String) else { continue }
			if let kind = entry["kind"] as? String {
				guard kind == "chat" else { continue }
			} else if notChat.contains(where: id.lowercased().contains) {
				continue
			}
			out.append(ModelInfo(id: id, workers: entry["workers"] as? [String] ?? []))
		}
		// Stable, so each half stays in the provider's own order.
		return out.filter(\.isAgent) + out.filter { !$0.isAgent }
	}

	/// One tool call a model asked for.
	public struct Call: Equatable, Sendable {
		public var id = ""
		public var name = ""
		/// The arguments object, as the JSON text it arrived as.
		public var arguments = ""
	}

	/// A streamed `chat/completions` answer, as far as it has got.
	///
	/// Fed one `data:` payload at a time. Tool calls arrive in pieces — a name
	/// in one chunk, the arguments spread over the next several, keyed by an
	/// index — so they are assembled here rather than by whoever reads them.
	public struct Answer: Equatable, Sendable {
		public var text = ""
		public var reasoning = ""
		public var calls: [Call] = []
		public var finish: String?
		public var error: String?
		public var done = false

		public init() {}

		public enum Piece: Equatable { case text(String), reasoning, calls, nothing }

		@discardableResult
		public mutating func apply(_ data: String) -> Piece {
			if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { done = true; return .nothing }
			guard let chunk = JSON.object(data) else { return .nothing }
			if let failure = chunk["error"] {
				error = ChatAPI.message(of: failure) ?? "error"
				return .nothing
			}
			guard let choice = (chunk["choices"] as? [JSONObject])?.first else { return .nothing }
			if let reason = choice["finish_reason"] as? String { finish = reason }
			guard let delta = choice["delta"] as? JSONObject else { return .nothing }
			var piece = Piece.nothing
			if let pieces = delta["tool_calls"] as? [JSONObject] {
				for (position, part) in pieces.enumerated() {
					let index = part["index"] as? Int ?? position
					while calls.count <= index { calls.append(Call()) }
					if let id = part["id"] as? String { calls[index].id = id }
					let function = part["function"] as? JSONObject
					if let name = function?["name"] as? String { calls[index].name += name }
					if let arguments = function?["arguments"] as? String {
						calls[index].arguments += arguments
					} else if let arguments = function?["arguments"] as? JSONObject {
						calls[index].arguments += JSON.text(arguments)
					}
				}
				piece = .calls
			}
			// `reasoning_content` from ai-connector and vLLM, `reasoning` from
			// OpenRouter and Ollama.
			if let thought = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
			   !thought.isEmpty {
				reasoning += thought
				piece = .reasoning
			}
			if let said = delta["content"] as? String, !said.isEmpty {
				text += said
				piece = .text(said)
			}
			return piece
		}
	}

	/// What an agent's job said, from ai-connector's event stream.
	public enum JobEvent: Equatable {
		/// A piece of the answer, and how many bytes of it came before.
		case text(String, at: Int?)
		case status(String)
		/// The job changed state; `done`, `failed` and `canceled` end it.
		case state(String)
		case other
	}

	/// Decodes one `data:` payload of `/api/events`. `nil` when it is about
	/// somebody else's job — the stream is everybody's.
	public static func jobEvent(_ data: String, job: String) -> JobEvent? {
		guard let event = JSON.object(data), event["jobId"] as? String == job else { return nil }
		if let job = event["job"] as? JSONObject {
			return .state(job["state"] as? String ?? "")
		}
		let inner = event["event"] as? JSONObject
		switch inner?["type"] as? String {
		case "text": return .text(inner?["text"] as? String ?? "", at: event["at"] as? Int)
		case "status": return .status(inner?["text"] as? String ?? "")
		default: return .other
		}
	}

	public static func jobFinished(_ state: String) -> Bool {
		["done", "failed", "canceled"].contains(state)
	}

	/// The sentence inside an error answer, whichever shape it came in:
	/// `{"error": {"message": …}}`, `{"error": "…", "message": "…"}`, or text.
	static func message(of failure: Any) -> String? {
		if let object = failure as? JSONObject {
			return (object["message"] as? String) ?? (object["error"] as? String)
		}
		return failure as? String
	}

	static func message(inBody body: String) -> String? {
		guard let object = JSON.object(body) else {
			let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
		}
		if let failure = object["error"], let inner = failure as? JSONObject {
			return message(of: inner)
		}
		return (object["message"] as? String) ?? (object["error"] as? String)
	}
}

/// What went wrong talking to a provider, as a sentence somebody can act on.
public enum ChatError: LocalizedError, Equatable {
	case notRunning
	case unauthorized(String?)
	case rateLimit(String?)
	case noTools(String?)
	case server(Int, String?)
	case network(String)
	/// The provider said no in its own words, part-way through an answer.
	case refused(String)
	case brokeOff

	/// Sorts a failed request by what somebody would do about it. The
	/// provider's own words go along in every case — they are the part worth
	/// quoting in a report.
	public static func from(status: Int, body: String) -> ChatError {
		let message = ChatAPI.message(inBody: body)
		let lowered = (message ?? "").lowercased()
		if lowered.contains("support tool") || lowered.contains("does not support tools")
			|| lowered.contains("enable-auto-tool-choice") {
			return .noTools(message)
		}
		switch status {
		case 401, 403: return .unauthorized(message)
		case 429: return .rateLimit(message)
		default: return .server(status, message)
		}
	}

	/// An error that arrived inside a stream, where there is no status to go by.
	public static func inStream(_ message: String) -> ChatError {
		if case .noTools = from(status: 0, body: message) { return .noTools(message) }
		return .refused(message)
	}

	public static func from(_ error: Error) -> ChatError {
		if let already = error as? ChatError { return already }
		let ns = error as NSError
		if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCannotConnectToHost {
			return .notRunning
		}
		return .network(error.localizedDescription)
	}

	public var errorDescription: String? {
		func with(_ sentence: String, _ theirs: String?) -> String {
			guard let theirs, !theirs.isEmpty else { return sentence }
			return "\(sentence) (\(theirs))"
		}
		switch self {
		case .notRunning: return "The AI is not answering — nothing is listening at its address."
		case .unauthorized(let m): return with("The AI refused the token.", m)
		case .rateLimit(let m): return with("Too many requests for now.", m)
		case .noTools(let m):
			return with("This model cannot call tools, so it cannot work in cuttr. Choose another.", m)
		case .server(let status, let m): return with("The AI answered with an error \(status).", m)
		case .network(let m): return "The AI could not be reached: \(m)"
		case .refused(let m): return "The AI stopped with an error: \(m)"
		case .brokeOff: return "The answer broke off."
		}
	}
}

/// One provider's API.
///
/// Two shapes, and the difference is one path component. ai-connector is
/// addressed by its root: the OpenAI API is below `/v1` and its own jobs API
/// below `/api`. Anything else is addressed by its OpenAI base, which already
/// ends in `/v1` or the provider's equivalent.
public struct ChatClient: Sendable {
	public var root: URL
	public var token: String?
	public var isConnector: Bool
	var session: URLSession

	public init(root: URL, token: String?, isConnector: Bool, session: URLSession? = nil) {
		self.root = root
		self.token = token
		self.isConnector = isConnector
		self.session = session ?? ChatClient.makeSession()
	}

	/// No cache and no cookies, and a long wait between bytes: an agent can
	/// think for minutes, and a stream that times out at sixty seconds of
	/// silence cuts off exactly the answers that were worth waiting for. The
	/// connector sends a ping every five seconds, so a dead one is still found.
	static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 120
		configuration.timeoutIntervalForResource = 60 * 60 * 6
		return URLSession(configuration: configuration)
	}

	private func request(_ path: String, body: JSONObject? = nil, timeout: TimeInterval? = nil) -> URLRequest {
		var base = root.absoluteString
		while base.hasSuffix("/") { base.removeLast() }
		var request = URLRequest(url: URL(string: base + path) ?? root)
		if let token, !token.isEmpty {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		if let timeout { request.timeoutInterval = timeout }
		if let body {
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try? JSONSerialization.data(withJSONObject: body)
		}
		return request
	}

	private var openAI: String { isConnector ? "/v1" : "" }

	private func load(_ request: URLRequest) async throws -> String {
		do {
			let (data, response) = try await session.data(for: request)
			let body = String(decoding: data, as: UTF8.self)
			let status = (response as? HTTPURLResponse)?.statusCode ?? 0
			guard (200..<300).contains(status) else { throw ChatError.from(status: status, body: body) }
			return body
		} catch {
			throw ChatError.from(error)
		}
	}

	public func models() async throws -> [ModelInfo] {
		ChatAPI.models(in: try await load(request(openAI + "/models", timeout: 8)))
	}

	/// The `data:` payloads of a server-sent stream, once the server has
	/// started answering.
	///
	/// Waits for the response's first line before it returns. For the event
	/// stream that is the point: a job submitted before anybody is listening
	/// can say its first words to nobody.
	private func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
		let bytes: URLSession.AsyncBytes
		do {
			let (opened, response) = try await session.bytes(for: request)
			let status = (response as? HTTPURLResponse)?.statusCode ?? 0
			guard (200..<300).contains(status) else {
				var body = ""
				for try await line in opened.lines { body += line + "\n"; if body.count > 4000 { break } }
				throw ChatError.from(status: status, body: body)
			}
			bytes = opened
		} catch {
			throw ChatError.from(error)
		}
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					for try await line in bytes.lines {
						guard line.hasPrefix("data:") else { continue }
						continuation.yield(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: ChatError.from(error))
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// A streamed completion. The caller's tools go along; the calls come back
	/// to be run, never run by the provider.
	public func chat(_ body: JSONObject) async throws -> AsyncThrowingStream<String, Error> {
		var body = body
		body["stream"] = true
		var request = request(openAI + "/chat/completions", body: body)
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		return try await stream(request)
	}

	// MARK: - Agents: ai-connector's jobs

	public func events() async throws -> AsyncThrowingStream<String, Error> {
		var request = request("/api/events")
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		return try await stream(request)
	}

	/// Submits a job and says its id.
	public func submit(_ job: JSONObject) async throws -> String {
		let body = try await load(request("/api/jobs", body: job))
		guard let id = JSON.object(body)?["id"] as? String else {
			throw ChatError.network("the job came back without an id")
		}
		return id
	}

	public func job(_ id: String) async throws -> JSONObject {
		JSON.object(try await load(request("/api/jobs/\(id)", timeout: 15))) ?? [:]
	}

	public func cancel(job id: String) async {
		_ = try? await load(request("/api/jobs/\(id)/cancel", body: [:], timeout: 10))
	}

	// MARK: - Linking a server on the network

	/// What the server answered when asked to link: a PIN to approve there.
	public struct Link: Equatable, Sendable {
		public var deviceCode: String
		public var pin: String
		public var approveAt: String
		public var interval: TimeInterval
	}

	public enum LinkState: Equatable, Sendable {
		case waiting
		case token(String)
		case refused(String)
	}

	/// Asks an ai-connector server on the network to link this app. Nothing is
	/// granted yet: a person approves the PIN on the server.
	public func startLink(name: String) async throws -> Link {
		let body = JSON.object(try await load(request("/api/link/start", body: ["name": name], timeout: 10)))
		guard let code = body?["device_code"] as? String, let pin = body?["user_code"] as? String else {
			throw ChatError.network("the server did not offer a PIN")
		}
		let page = (body?["verification_uri_complete"] as? String) ?? (body?["verification_uri"] as? String) ?? ""
		return Link(deviceCode: code, pin: pin, approveAt: page,
		            interval: (body?["interval"] as? Double) ?? 5)
	}

	/// Asks whether the PIN has been approved yet. The token is handed over
	/// exactly once.
	public func pollLink(_ link: Link) async -> LinkState {
		do {
			let body = JSON.object(try await load(
				request("/api/link/token", body: ["device_code": link.deviceCode], timeout: 10)))
			if let token = body?["token"] as? String { return .token(token) }
			return .waiting
		} catch ChatError.server(_, let message) {
			switch message {
			case "authorization_pending", "slow_down": return .waiting
			case "access_denied": return .refused("The link was declined on the server.")
			default: return .refused("The PIN expired. Start again.")
			}
		} catch {
			return .waiting
		}
	}
}
