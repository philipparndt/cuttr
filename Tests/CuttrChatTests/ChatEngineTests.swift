import Foundation
import Testing
@testable import CuttrChat

/// An app with two tools: one that just answers, and one that asks first.
@MainActor
private final class FakeApp: ChatToolHost {
	var calls: [(name: String, arguments: JSONObject)] = []

	let tools = [
		ToolDefinition("seek", "Moves the playhead.", [("time", .string("Where to."))], required: ["time"]),
		ToolDefinition("save_all", "Writes everything."),
	]
	let instructions = "You are in a test."

	func call(_ name: String, arguments: JSONObject) async -> ToolResult {
		calls.append((name, arguments))
		if name == "seek" { return ToolResult("The playhead is at \(arguments["time"] ?? "?").") }
		return ToolResult("saved 2 documents", summary: "Saved 2 documents")
	}

	func question(before name: String, arguments: JSONObject) -> String? {
		name == "save_all" ? "Save every document that has changed?" : nil
	}

	func context() -> String { "cuttr, now — on screen: take “demo”" }
}

private func chunk(_ delta: String) -> String { #"{"choices":[{"delta":\#(delta)}]}"# }

@MainActor
@Suite struct ChatEngineTests {

	private let fake = FakeProvider.Stage()
	private let folder: URL
	private let app = FakeApp()

	init() throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	}

	/// An engine whose one provider is a connector "on this Mac", answered by
	/// the fake.
	private func engine(store: Bool = false) throws -> ChatEngine {
		let discovery = folder.appendingPathComponent("local-ai.json")
		try #"{"url":"\#(fake.root.absoluteString)","token":"aic_local"}"#
			.write(to: discovery, atomically: true, encoding: .utf8)
		return ChatEngine(
			host: app,
			store: store ? ChatStore(file: folder.appendingPathComponent("chat.json")) : nil,
			settings: { ProviderSettings() },
			discoveryFile: discovery,
			session: fake.session())
	}

	private func wait(_ what: String = "the turn to end", until done: @MainActor () -> Bool) async {
		for _ in 0..<2000 {
			if done() { return }
			try? await Task.sleep(nanoseconds: 2_000_000)
		}
		Issue.record("waited four seconds for \(what)")
	}


	// MARK: - Who answers

	@Test func withNoConnectorThereIsNobodyAndItSaysSo() async {
		let engine = ChatEngine(host: app, store: nil, settings: { ProviderSettings() },
		                        discoveryFile: folder.appendingPathComponent("local-ai.json"),
		                        session: fake.session())
		#expect(engine.link == .looking)
		await engine.refresh()
		#expect(engine.link == .missing)
		#expect(engine.chosen == nil)
		#expect(engine.problem == nil)
		// And a message typed anyway goes nowhere rather than into a void.
		engine.send("hello")
		#expect(engine.conversation.entries.isEmpty)
	}

	@Test func aConnectorThatDoesNotAnswerIsMissingWithAReason() async throws {
		fake.handler = { _, _, reply in
			reply.json(#"{"error":{"message":"token unknown"}}"#, status: 401)
		}
		let engine = try engine()
		await engine.refresh()
		#expect(engine.link == .missing)
		#expect(engine.problem == "This Mac: The AI refused the token. (token unknown)")
	}

	@Test func modelsAreOfferedAndTheChoiceIsKept() async throws {
		fake.handler = { _, _, reply in
			reply.json(#"{"data":[{"id":"qwen","kind":"chat"},{"id":"claude-code/sonnet","kind":"chat"}]}"#)
		}
		let first = try engine(store: true)
		await first.refresh()
		#expect(first.link == .connected)
		#expect(first.choices.map(\.key) == ["local/claude-code/sonnet", "local/qwen"])
		#expect(first.chosen?.model.id == "claude-code/sonnet")
		first.choose("local/qwen")

		let second = try engine(store: true)
		await second.refresh()
		#expect(second.chosen?.model.id == "qwen")
	}

	// MARK: - A model

	@Test func aModelCallsAToolAndThenAnswers() async throws {
		nonisolated(unsafe) var round = 0
		fake.handler = { path, _, reply in
			guard path == "/v1/chat/completions" else {
				reply.json(#"{"data":[{"id":"qwen","kind":"chat"}]}"#)
				return
			}
			round += 1
			if round == 1 {
				reply.events([
					chunk(#"{"content":"Going there."}"#),
					chunk(#"{"tool_calls":[{"index":0,"id":"c1","function":{"name":"seek","arguments":"{\"time\":\"00:07\"}"}}]}"#),
					#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "[DONE]",
				])
			} else {
				reply.events([chunk(#"{"content":"You are at **00:07**."}"#), "[DONE]"])
			}
		}
		let engine = try engine(store: true)
		await engine.refresh()
		engine.send("  go to seven seconds ")
		#expect(engine.isWorking)
		await wait { !engine.isWorking }

		#expect(app.calls.map(\.name) == ["seek"])
		#expect(app.calls.first?.arguments["time"] as? String == "00:07")
		let entries = engine.conversation.entries
		#expect(entries.map(\.role) == [.user, .assistant])
		#expect(entries[0].text == "go to seven seconds")
		#expect(entries[1].text == "Going there.\n\nYou are at **00:07**.")
		#expect(entries[1].status == .done)
		#expect(entries[1].tools.map(\.state) == [.done])
		#expect(entries[1].tools.first?.summary == "The playhead is at 00:07.")

		// What went to the model: the app's instructions, what is on screen with
		// the question, the tools — and on the second round, what the call said.
		let rounds = fake.seen.filter { $0.path == "/v1/chat/completions" }
		#expect(rounds.count == 2)
		#expect(rounds[0].token == "Bearer aic_local")
		#expect(rounds[0].body["model"] as? String == "qwen")
		#expect((rounds[0].body["tools"] as? [JSONObject])?.count == 2)
		let first = try #require(rounds[0].body["messages"] as? [JSONObject])
		#expect(first.first?["content"] as? String == "You are in a test.")
		#expect(first.last?["content"] as? String == "[cuttr, now — on screen: take “demo”]\n\ngo to seven seconds")
		let second = try #require(rounds[1].body["messages"] as? [JSONObject])
		#expect(second.suffix(2).map { $0["role"] as? String } == ["assistant", "tool"])
		#expect(second.last?["tool_call_id"] as? String == "c1")
		#expect(second.last?["content"] as? String == "The playhead is at 00:07.")

		// And it is on disk, for the next launch.
		let kept = ChatStore(file: folder.appendingPathComponent("chat.json")).load()
		#expect(kept.entries == entries)
	}

	@Test func aCallThatAsksFirstWaitsAndADeclineIsToldToTheModel() async throws {
		nonisolated(unsafe) var round = 0
		fake.handler = { path, _, reply in
			guard path == "/v1/chat/completions" else {
				reply.json(#"{"data":[{"id":"qwen","kind":"chat"}]}"#)
				return
			}
			round += 1
			if round == 1 {
				reply.events([
					chunk(#"{"tool_calls":[{"index":0,"id":"c1","function":{"name":"save_all","arguments":""}}]}"#),
					"[DONE]",
				])
			} else {
				reply.events([chunk(#"{"content":"Left unsaved."}"#), "[DONE]"])
			}
		}
		let engine = try engine()
		await engine.refresh()
		engine.send("save it")
		await wait("the question") { engine.confirmation != nil }

		#expect(engine.confirmation?.question == "Save every document that has changed?")
		#expect(app.calls.isEmpty, "nothing runs until somebody has answered")
		#expect(engine.conversation.entries.last?.tools.map(\.state) == [.asking])

		engine.decide(false)
		await wait { !engine.isWorking }
		#expect(app.calls.isEmpty)
		#expect(engine.confirmation == nil)
		#expect(engine.conversation.entries.last?.tools.map(\.state) == [.declined])
		#expect(engine.conversation.entries.last?.text == "Left unsaved.")
		let told = fake.seen.last?.body["messages"] as? [JSONObject]
		#expect((told?.last?["content"] as? String ?? "").contains("declined"))
	}

	@Test func allowingRunsTheCall() async throws {
		nonisolated(unsafe) var round = 0
		fake.handler = { path, _, reply in
			guard path == "/v1/chat/completions" else {
				reply.json(#"{"data":[{"id":"qwen","kind":"chat"}]}"#)
				return
			}
			round += 1
			reply.events(round == 1
				? [chunk(#"{"tool_calls":[{"index":0,"id":"c1","function":{"name":"save_all","arguments":"{}"}}]}"#), "[DONE]"]
				: [chunk(#"{"content":"Saved."}"#), "[DONE]"])
		}
		let engine = try engine()
		await engine.refresh()
		engine.send("save it")
		await wait("the question") { engine.confirmation != nil }
		engine.decide(true)
		await wait { !engine.isWorking }
		#expect(app.calls.map(\.name) == ["save_all"])
		#expect(engine.conversation.entries.last?.tools.first?.summary == "Saved 2 documents")
	}

	@Test func aFailureIsShownAndAMessageTypedMeanwhileWaits() async throws {
		nonisolated(unsafe) var held: FakeProvider.Reply?
		fake.handler = { path, _, reply in
			guard path == "/v1/chat/completions" else {
				reply.json(#"{"data":[{"id":"qwen","kind":"chat"}]}"#)
				return
			}
			reply.open(type: "text/event-stream")
			held = reply
		}
		let engine = try engine()
		await engine.refresh()
		engine.send("first")
		engine.send("second")
		#expect(engine.queue == ["second"])
		await wait("the request") { held != nil }
		held?.send("data: {\"error\":{\"message\":\"no worker\"}}\n\ndata: [DONE]\n\n")
		held?.finish()
		await wait { !engine.isWorking }

		let answer = try #require(engine.conversation.entries.last)
		#expect(answer.status == .failed)
		#expect(answer.problem == "The AI stopped with an error: no worker")
		// After a failure the queue waits: what was typed next expected an answer.
		#expect(engine.queue == ["second"])
		#expect(engine.conversation.entries.count == 2)
	}

	@Test func stoppingEndsTheTurnAndClearingStartsANewConversation() async throws {
		nonisolated(unsafe) var held: FakeProvider.Reply?
		fake.handler = { path, _, reply in
			guard path == "/v1/chat/completions" else {
				reply.json(#"{"data":[{"id":"qwen","kind":"chat"}]}"#)
				return
			}
			reply.open(type: "text/event-stream")
			reply.send("data: \(chunk(#"{"content":"Half an ans"}"#))\n\n")
			held = reply
		}
		let engine = try engine()
		await engine.refresh()
		engine.send("tell me")
		await wait("the first words") { engine.conversation.entries.last?.text == "Half an ans" }
		engine.stop()
		await wait { !engine.isWorking }
		#expect(engine.conversation.entries.last?.status == .stopped)
		#expect(engine.conversation.entries.last?.text == "Half an ans")

		let before = engine.conversation.id
		engine.clear()
		#expect(engine.conversation.entries.isEmpty)
		#expect(engine.conversation.id != before)
		_ = held
	}

	// MARK: - An agent

	@Test func anAgentWorksThroughTheAppsOwnServer() async throws {
		nonisolated(unsafe) var events: FakeProvider.Reply?
		nonisolated(unsafe) var job: JSONObject = [:]
		fake.handler = { path, body, reply in
			switch path {
			case "/v1/models":
				reply.json(#"{"data":[{"id":"claude-code/sonnet","kind":"chat"}]}"#)
			case "/api/events":
				reply.open(type: "text/event-stream")
				reply.send(": ping\n\n")
				events = reply
			case "/api/jobs":
				job = body
				reply.json(#"{"id":"j1"}"#)
				// The agent, played by the test: it calls a tool on the server
				// the job named, with the token the job gave it, then says its
				// piece and finishes.
				let server = (body["mcp"] as? [JSONObject])?.first
				let token = (server?["headers"] as? [String: String])?["Authorization"] ?? ""
				var call = URLRequest(url: URL(string: server?["url"] as? String ?? "")!)
				call.httpMethod = "POST"
				call.setValue(token, forHTTPHeaderField: "Authorization")
				call.httpBody = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"seek","arguments":{"time":"00:03"}}}"#.utf8)
				URLSession.shared.dataTask(with: call) { data, _, _ in
					let said = String(decoding: data ?? Data(), as: UTF8.self)
					#expect(said.contains("The playhead is at 00:03."))
					events?.send(#"data: {"jobId":"other","event":{"type":"text","text":"not mine"}}"# + "\n\n")
					events?.send(#"data: {"jobId":"j1","at":0,"event":{"type":"text","text":"Mov"}}"# + "\n\n")
					events?.send(#"data: {"jobId":"j1","at":1,"event":{"type":"text","text":"oved."}}"# + "\n\n")
					events?.send(#"data: {"jobId":"j1","job":{"state":"done"}}"# + "\n\n")
				}.resume()
			case "/api/jobs/j1":
				reply.json(#"{"id":"j1","state":"done","text":"Moved to 00:03."}"#)
			default:
				reply.json("{}")
			}
		}
		let engine = try engine()
		await engine.refresh()
		engine.send("go to three seconds")
		await wait { !engine.isWorking }

		#expect(app.calls.map(\.name) == ["seek"])
		let answer = try #require(engine.conversation.entries.last)
		#expect(answer.status == .done)
		// The job as the connector has it at the end, not the pieces heard.
		#expect(answer.text == "Moved to 00:03.")
		#expect(answer.tools.map(\.name) == ["seek"])

		#expect(job["model"] as? String == "claude-code/sonnet")
		#expect(job["session"] as? String == "cuttr:\(engine.conversation.id)")
		#expect(job["fresh"] as? Bool == true)
		let server = try #require((job["mcp"] as? [JSONObject])?.first)
		#expect(server["name"] as? String == "cuttr")
		#expect((server["url"] as? String ?? "").hasPrefix("http://127.0.0.1:"))
		// Listening before asking.
		let order = fake.seen.map(\.path).filter { $0.hasPrefix("/api/") }
		#expect(Array(order.prefix(2)) == ["/api/events", "/api/jobs"])

		// The second turn continues the agent's own session.
		events = nil
		engine.send("and again")
		await wait { !engine.isWorking }
		#expect(job["fresh"] as? Bool == false)
	}

	// MARK: - The server on its own

	@Test func theAppsServerAnswersOnlyTheAgentItWasOpenedFor() async throws {
		let app = self.app
		let server = MCPServer(tools: { app.tools }, call: { name, arguments in
			await app.call(name, arguments: arguments)
		})
		let url = try await server.start()
		defer { server.stop() }

		func ask(_ body: String, token: String? = nil, origin: String? = nil,
		         method: String = "POST") async throws -> (Int, JSONObject) {
			var request = URLRequest(url: url)
			request.httpMethod = method
			if method == "POST" { request.httpBody = Data(body.utf8) }
			request.setValue("Bearer \(token ?? server.token)", forHTTPHeaderField: "Authorization")
			if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
			let (data, response) = try await URLSession.shared.data(for: request)
			return ((response as? HTTPURLResponse)?.statusCode ?? 0,
			        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject ?? [:])
		}

		let (ok, hello) = try await ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
		#expect(ok == 200)
		let result = hello["result"] as? JSONObject
		#expect(result?["protocolVersion"] as? String == "2025-06-18")
		#expect((result?["capabilities"] as? JSONObject)?["tools"] != nil)

		let (accepted, _) = try await ask(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
		#expect(accepted == 202)

		let (_, listed) = try await ask(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
		let tools = (listed["result"] as? JSONObject)?["tools"] as? [JSONObject]
		#expect(tools?.compactMap { $0["name"] as? String } == ["seek", "save_all"])
		#expect(((tools?.first?["inputSchema"] as? JSONObject)?["required"] as? [String]) == ["time"])

		let (_, called) = try await ask(#"{"jsonrpc":"2.0","id":"x","method":"tools/call","params":{"name":"seek","arguments":{"time":"00:01"}}}"#)
		#expect(called["id"] as? String == "x")
		let content = ((called["result"] as? JSONObject)?["content"] as? [JSONObject])?.first
		#expect(content?["text"] as? String == "The playhead is at 00:01.")
		#expect((called["result"] as? JSONObject)?["isError"] as? Bool == false)

		let (_, unknown) = try await ask(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
		#expect((unknown["error"] as? JSONObject)?["code"] as? Int == -32601)

		// Not without the token, not from a web page, and not by any other verb.
		let (refused, _) = try await ask(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#, token: "guess")
		#expect(refused == 401)
		let (browser, _) = try await ask(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#, origin: "https://example.org")
		#expect(browser == 403)
		let (get, _) = try await ask("", method: "GET")
		#expect(get == 405)
		#expect(app.calls.count == 1)
	}

	@Test func aRequestIsReadOnlyOnceAllOfItHasArrived() {
		let whole = Data("POST /mcp HTTP/1.1\r\nContent-Length: 4\r\nAuthorization: Bearer t\r\n\r\nabcdPOST".utf8)
		#expect(MCPServer.parse(whole.prefix(20)) == nil)
		#expect(MCPServer.parse(whole.prefix(whole.count - 6)) == nil)
		let parsed = MCPServer.parse(whole)
		#expect(parsed?.request.method == "POST")
		#expect(parsed?.request.headers["authorization"] == "Bearer t")
		#expect(parsed?.request.body == Data("abcd".utf8))
		#expect(parsed?.length == whole.count - 4)
	}

	// MARK: - Keeping it

	@Test func anAnswerThatWasBeingWrittenWhenTheAppQuitIsNotStillBeingWritten() {
		let store = ChatStore(file: folder.appendingPathComponent("kept/chat.json"))
		var conversation = Conversation()
		conversation.entries = [ChatEntry(role: .user, text: "hi"),
		                        ChatEntry(role: .assistant, text: "Half", status: .working)]
		conversation.entries[1].tools = [ChatEntry.Tool(name: "seek", arguments: "{}")]
		store.save(conversation)

		let kept = store.load()
		#expect(kept.id == conversation.id)
		#expect(kept.entries[1].status == .stopped)
		#expect(kept.entries[1].tools[0].state == .failed)
		let mode = try? FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
		#expect(mode == 0o600)
	}
}
