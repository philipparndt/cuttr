import Foundation
import Testing
@testable import CuttrChat

@Suite struct ChatAPITests {

	// MARK: - Finding the connector

	@Test func theConnectorsFolderFollowsItsOwnRules() {
		#expect(Connector.directory(environment: ["MLXLAB_HOME": "/x/lab"], home: "/h").path == "/x/lab")
		#expect(Connector.directory(environment: ["XDG_CONFIG_HOME": "/x"], home: "/h").path == "/x/mlxlab")
		#expect(Connector.directory(environment: [:], home: "/h").path == "/h/.config/mlxlab")
	}

	@Test func theDiscoveryFileIsReadAndItsTokenNeverPrinted() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let file = folder.appendingPathComponent("local-ai.json")

		// No file is the ordinary case, and not an error.
		#expect(try Connector.discovery(at: file) == nil)

		try #"{"url":"http://127.0.0.1:52817","token":"aic_secret","pid":4711}"#
			.write(to: file, atomically: true, encoding: .utf8)
		let found = try #require(try Connector.discovery(at: file))
		#expect(found.url == "http://127.0.0.1:52817")
		#expect(found.token == "aic_secret")
		#expect(found.pid == 4711)
		#expect(!("\(found)".contains("aic_secret")))
		#expect(!(String(reflecting: found).contains("aic_secret")))

		// There and broken is said, rather than read as "not set up".
		try #"{"url":"http://127.0.0.1:1"}"#.write(to: file, atomically: true, encoding: .utf8)
		#expect(throws: (any Error).self) { try Connector.discovery(at: file) }
	}

	@Test func theSetupCommandRunsAScriptThatInstallsAndStartsTheConnector() throws {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("cuttr setup \(UUID().uuidString)")
		let script = try Connector.writeSetupScript(into: folder)
		let written = try String(contentsOf: script, encoding: .utf8)
		#expect(written.hasPrefix("#!/bin/sh\n"))
		#expect(written.contains("local --install"))
		#expect(written.contains("checksum mismatch"))
		// A folder with a space in it is one word to the shell.
		#expect(Connector.setupCommand(script: script) == "sh '\(script.path)'")
		#expect(Connector.shellQuote("/Users/me/.config/cuttr/ai-setup.sh") == "/Users/me/.config/cuttr/ai-setup.sh")
		#expect(Connector.shellQuote("it's") == "'it'\\''s'")
	}

	@Test func theSetupScriptIsValidShell() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let script = try Connector.writeSetupScript(into: folder)
		let check = Process()
		check.executableURL = URL(fileURLWithPath: "/bin/sh")
		check.arguments = ["-n", script.path]
		try check.run()
		check.waitUntilExit()
		#expect(check.terminationStatus == 0)
	}

	@Test func providersAreFoundInOrderAndOnlyThisMacRunsAgents() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let file = folder.appendingPathComponent("local-ai.json")
		let settings = ProviderSettings(serverURL: "http://studio.local:8485", serverToken: "aic_x",
		                                openAIURL: "https://openrouter.ai/api/v1", openAIKey: "sk")

		#expect(Providers.find(settings: settings, discoveryFile: file).map(\.id) == ["server", "openai"])
		#expect(Providers.find(settings: ProviderSettings(), discoveryFile: file) == [])

		try #"{"url":"http://127.0.0.1:52817","token":"t"}"#.write(to: file, atomically: true, encoding: .utf8)
		let all = Providers.find(settings: settings, discoveryFile: file)
		#expect(all.map(\.id) == ["local", "server", "openai"])
		#expect(all.map(\.runsAgents) == [true, false, false])
		// A server without a token has not been linked, and is not offered.
		#expect(Providers.find(settings: ProviderSettings(serverURL: "http://studio.local:8485"),
		                              discoveryFile: file).map(\.id) == ["local"])
	}

	// MARK: - What a provider says

	@Test func modelsAreChatModelsWithAgentsFirst() {
		let connector = #"""
		{"data":[{"id":"qwen3.6-35b-a3b","kind":"chat","workers":["Mac Studio"]},
		         {"id":"qwen3-embedding-0.6b","kind":"embed"},
		         {"id":"claude-code/sonnet","kind":"chat","workers":["Mac Studio"]}]}
		"""#
		let models = ChatAPI.models(in: connector)
		#expect(models.map(\.id) == ["claude-code/sonnet", "qwen3.6-35b-a3b"])
		#expect(models.map(\.isAgent) == [true, false])
		#expect(models[0].label == "Claude Code (Sonnet)")
		#expect(models[1].workers == ["Mac Studio"])

		// A list that only gives names has the ones that are no chat taken out.
		let openAI = #"{"data":[{"id":"gpt-5"},{"id":"text-embedding-3-small"},{"id":"whisper-1"}]}"#
		#expect(ChatAPI.models(in: openAI).map(\.id) == ["gpt-5"])
		#expect(ChatAPI.models(in: #"{"models":[{"model":"qwen3:8b"}]}"#).map(\.id) == ["qwen3:8b"])
		#expect(ChatAPI.models(in: "not json") == [])
	}

	@Test func aStreamedAnswerIsAssembledFromItsPieces() {
		var answer = ChatAPI.Answer()
		#expect(answer.apply(#"{"choices":[{"delta":{"role":"assistant"}}]}"#) == .nothing)
		#expect(answer.apply(#"{"choices":[{"delta":{"reasoning_content":"hm"}}]}"#) == .reasoning)
		#expect(answer.apply(#"{"choices":[{"delta":{"content":"Mov"}}]}"#) == .text("Mov"))
		#expect(answer.apply(#"{"choices":[{"delta":{"content":"ing."}}]}"#) == .text("ing."))
		// A call's name in one chunk and its arguments over the next two.
		#expect(answer.apply(
			#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"seek","arguments":"{\"ti"}}]}}]}"#) == .calls)
		answer.apply(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"me\":3}"}}]}}]}"#)
		answer.apply(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
		#expect(!answer.done)
		answer.apply("[DONE]")

		#expect(answer.text == "Moving.")
		#expect(answer.reasoning == "hm")
		#expect(answer.calls == [ChatAPI.Call(id: "c1", name: "seek", arguments: #"{"time":3}"#)])
		#expect(answer.finish == "tool_calls")
		#expect(answer.done)

		var failed = ChatAPI.Answer()
		failed.apply(#"{"error":{"message":"no worker","code":"no_worker"}}"#)
		#expect(failed.error == "no worker")
	}

	@Test func aJobsEventsAreItsOwnAndNobodyElses() {
		#expect(ChatAPI.jobEvent(#"{"jobId":"other","event":{"type":"text","text":"x"}}"#, job: "j1") == nil)
		#expect(ChatAPI.jobEvent(#"{"jobId":"j1","at":4,"event":{"type":"text","text":"x"}}"#, job: "j1") == .text("x", at: 4))
		#expect(ChatAPI.jobEvent(#"{"jobId":"j1","event":{"type":"status","text":"Reading"}}"#, job: "j1") == .status("Reading"))
		#expect(ChatAPI.jobEvent(#"{"jobId":"j1","job":{"state":"done"}}"#, job: "j1") == .state("done"))
		#expect(ChatAPI.jobFinished("canceled"))
		#expect(!ChatAPI.jobFinished("running"))
	}

	@Test func failuresAreSortedByWhatSomebodyWouldDoAboutThem() {
		#expect(ChatError.from(status: 401, body: #"{"error":{"message":"bad key","code":"invalid_api_key"}}"#) == .unauthorized("bad key"))
		#expect(ChatError.from(status: 429, body: "") == .rateLimit(nil))
		#expect(ChatError.from(status: 404, body: #"{"error":{"message":"No endpoints found that support tool use"}}"#) == .noTools("No endpoints found that support tool use"))
		#expect(ChatError.from(status: 503, body: #"{"error":{"message":"no worker"}}"#) == .server(503, "no worker"))
		#expect(ChatError.from(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)) == .notRunning)
		#expect(ChatError.inStream("registry.ollama.ai/x does not support tools") == .noTools("registry.ollama.ai/x does not support tools"))
		// Their words go along, because they are what a report should quote.
		#expect(ChatError.server(503, "no worker").localizedDescription.contains("no worker"))
	}

	// MARK: - The client

	@Test func aConnectorIsAskedBelowV1AndAnOpenAIBaseAsItIs() async throws {
		let fake = FakeProvider.Stage()
		fake.handler = { _, _, reply in reply.json(#"{"data":[{"id":"m","kind":"chat"}]}"#) }
		let session = fake.session()

		_ = try await ChatClient(root: fake.root, token: "t",
		                         isConnector: true, session: session).models()
		_ = try await ChatClient(root: fake.root.appendingPathComponent("api/v1"), token: nil,
		                         isConnector: false, session: session).models()

		#expect(fake.seen.map(\.path) == ["/v1/models", "/api/v1/models"])
		#expect(fake.seen.map(\.token) == ["Bearer t", nil])
	}

	@Test func aFailedRequestSaysWhatTheProviderSaid() async {
		let fake = FakeProvider.Stage()
		fake.handler = { _, _, reply in
			reply.json(#"{"error":{"message":"token unknown","code":"invalid_api_key"}}"#, status: 401)
		}
		let client = ChatClient(root: fake.root, token: "t",
		                        isConnector: true, session: fake.session())
		do {
			_ = try await client.models()
			Issue.record("a 401 is not a list of models")
		} catch {
			#expect(error as? ChatError == .unauthorized("token unknown"))
		}
		do {
			_ = try await client.chat(["model": "m"])
			Issue.record("a 401 is not an answer")
		} catch {
			#expect(error as? ChatError == .unauthorized("token unknown"))
		}
	}

	@Test func linkingWaitsForThePinToBeApproved() async throws {
		let fake = FakeProvider.Stage()
		nonisolated(unsafe) var polls = 0
		fake.handler = { path, body, reply in
			switch path {
			case "/api/link/start":
				#expect(body["name"] as? String == "cuttr")
				reply.json(#"{"device_code":"dc","user_code":"123 456","verification_uri_complete":"http://s/pin/123456","interval":5}"#)
			default:
				#expect(body["device_code"] as? String == "dc")
				polls += 1
				if polls == 1 { reply.json(#"{"error":"authorization_pending"}"#, status: 400) }
				else { reply.json(#"{"token":"aic_new"}"#) }
			}
		}
		let client = ChatClient(root: fake.root, token: nil, isConnector: true,
		                        session: fake.session())
		let link = try await client.startLink(name: "cuttr")
		#expect(link.pin == "123 456")
		#expect(link.approveAt == "http://s/pin/123456")
		let first = await client.pollLink(link)
		#expect(first == .waiting)
		let second = await client.pollLink(link)
		#expect(second == .token("aic_new"))
	}
}
