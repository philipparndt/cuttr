import Foundation
import Network

/// The app's tools, as an MCP server on the loopback interface.
///
/// This is how an agent works in the app. Claude Code does not hand its tool
/// calls back to be run — it runs its own loop and calls MCP servers — so for
/// the length of a turn the app is one: the job names this address and this
/// token, and the agent's calls arrive here as HTTP.
///
/// Small on purpose. MCP's streamable HTTP transport lets a server answer
/// every request with plain JSON and open no stream of its own, and that is
/// all this does: `initialize`, `tools/list`, `tools/call`, `ping`. One
/// connection handles one request at a time, in order.
///
/// Three things keep it to the agent it was opened for. It binds to 127.0.0.1
/// and nothing else. Every request needs the bearer token, which is made new
/// each launch and goes only into the job. And a request carrying an `Origin`
/// is refused: a browser sends one and an agent does not, so a web page that
/// talks its way to the port still cannot use it.
public final class MCPServer: @unchecked Sendable {

	public typealias Tools = @MainActor () -> [ToolDefinition]
	public typealias Call = @MainActor (_ name: String, _ arguments: JSONObject) async -> ToolResult

	public let token: String
	public private(set) var url: URL?

	private let tools: Tools
	private let call: Call
	private var listener: NWListener?
	private let queue = DispatchQueue(label: "de.rnd7.cuttr.chat.mcp")

	public init(tools: @escaping Tools, call: @escaping Call) {
		self.tools = tools
		self.call = call
		// The system generator, which on this platform is the secure one.
		var generator = SystemRandomNumberGenerator()
		token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
			.joined()
	}

	deinit { listener?.cancel() }

	/// Starts listening, on a port the system picks, and says the address.
	/// Asking again answers with the same one.
	@discardableResult
	public func start() async throws -> URL {
		if let url { return url }
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
		parameters.acceptLocalOnly = true
		let listener = try NWListener(using: parameters)
		self.listener = listener
		listener.newConnectionHandler = { [weak self] connection in
			guard let self else { connection.cancel(); return }
			connection.start(queue: self.queue)
			self.receive(on: connection, buffer: Data())
		}
		let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
			// A listener goes on reporting its state for as long as it lives,
			// and a continuation may be answered once. Every report arrives on
			// the one serial queue, so a flag is enough to tell the first.
			let once = Once()
			listener.stateUpdateHandler = { state in
				switch state {
				case .ready:
					if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
				case .failed(let error):
					if once.take() { continuation.resume(throwing: error) }
				case .cancelled:
					if once.take() { continuation.resume(throwing: CancellationError()) }
				default: break
				}
			}
			listener.start(queue: queue)
		}
		let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
		self.url = url
		return url
	}

	public func stop() {
		listener?.cancel()
		listener = nil
		url = nil
	}

	private final class Once: @unchecked Sendable {
		private var taken = false
		func take() -> Bool {
			if taken { return false }
			taken = true
			return true
		}
	}

	// MARK: - HTTP

	struct Request {
		var method: String
		var headers: [String: String]
		var body: Data
	}

	/// One request off the front of the buffer, and how many bytes it took.
	/// `nil` while it has not all arrived.
	static func parse(_ buffer: Data) -> (request: Request, length: Int)? {
		guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
		let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
		var lines = head.components(separatedBy: "\r\n")
		let first = lines.removeFirst().split(separator: " ")
		var headers: [String: String] = [:]
		for line in lines {
			guard let colon = line.firstIndex(of: ":") else { continue }
			headers[line[..<colon].lowercased()] =
				line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
		}
		let length = Int(headers["content-length"] ?? "") ?? 0
		let bodyStart = end.upperBound
		guard buffer.endIndex - bodyStart >= length else { return nil }
		let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
		return (Request(method: first.first.map(String.init) ?? "", headers: headers, body: body),
		        bodyStart - buffer.startIndex + length)
	}

	private func receive(on connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
			[weak self] data, _, finished, error in
			guard let self else { connection.cancel(); return }
			var buffer = buffer
			if let data { buffer.append(data) }
			if let (request, length) = Self.parse(buffer) {
				let rest = Data(buffer.dropFirst(length))
				Task {
					let (status, body) = await self.answer(request)
					self.send(status: status, body: body, on: connection) {
						self.receive(on: connection, buffer: rest)
					}
				}
				return
			}
			// 64 MB of headers with no end is not somebody's request.
			if finished || error != nil || buffer.count > 64 << 20 {
				connection.cancel()
				return
			}
			self.receive(on: connection, buffer: buffer)
		}
	}

	private func send(status: String, body: Data, on connection: NWConnection,
	                  then next: @escaping () -> Void) {
		var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n"
		if !body.isEmpty { head += "Content-Type: application/json\r\n" }
		if status.hasPrefix("405") { head += "Allow: POST\r\n" }
		head += "\r\n"
		connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { error in
			if error != nil { connection.cancel() } else { next() }
		})
	}

	// MARK: - JSON-RPC

	func answer(_ request: Request) async -> (status: String, body: Data) {
		func failure(_ status: String, _ message: String) -> (String, Data) {
			(status, Data(JSON.text(["error": message]).utf8))
		}
		// A browser says where a request came from; an agent does not.
		if request.headers["origin"] != nil { return failure("403 Forbidden", "origin") }
		guard request.headers["authorization"] == "Bearer \(token)" else {
			return failure("401 Unauthorized", "token")
		}
		guard request.method == "POST" else { return failure("405 Method Not Allowed", "POST only") }
		return await respond(to: request.body)
	}

	@MainActor
	private func respond(to body: Data) async -> (status: String, body: Data) {
		func reply(_ id: Any, _ key: String, _ value: Any) -> (String, Data) {
			("200 OK", Data(JSON.text(["jsonrpc": "2.0", "id": id, key: value] as JSONObject).utf8))
		}
		guard let message = (try? JSONSerialization.jsonObject(with: body)) as? JSONObject,
		      let method = message["method"] as? String
		else {
			return reply(NSNull(), "error", ["code": -32700, "message": "Parse error"] as JSONObject)
		}
		// No id is a notification: taken, and nothing is said back.
		guard let id = message["id"] else { return ("202 Accepted", Data()) }
		let params = message["params"] as? JSONObject ?? [:]
		switch method {
		case "initialize":
			return reply(id, "result", [
				"protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
				"capabilities": ["tools": [:] as JSONObject] as JSONObject,
				"serverInfo": ["name": "cuttr", "version": "1"] as JSONObject,
			] as JSONObject)
		case "ping":
			return reply(id, "result", [:] as JSONObject)
		case "tools/list":
			return reply(id, "result", ["tools": tools().map(\.mcp)] as JSONObject)
		case "tools/call":
			guard let name = params["name"] as? String else {
				return reply(id, "error", ["code": -32602, "message": "No tool named"] as JSONObject)
			}
			let result = await call(name, params["arguments"] as? JSONObject ?? [:])
			return reply(id, "result", [
				"content": [["type": "text", "text": result.text] as JSONObject],
				"isError": result.isError,
			] as JSONObject)
		default:
			return reply(id, "error", ["code": -32601, "message": "Method not found: \(method)"] as JSONObject)
		}
	}
}
