import Foundation

/// The conversation with the assistant: who answers, what was said, and the
/// turn in progress.
///
/// Two ways an answer gets made, and they end in the same place.
///
/// A **model** — a local chat model, or anything behind an OpenAI-compatible
/// address — is sent the app's tools with the question. It answers with the
/// calls it wants made; the app makes them and sends back what happened, and
/// that goes round until it answers in words.
///
/// An **agent** — Claude Code, through ai-connector — runs that loop itself.
/// It is given the address of the app's own MCP server for the length of the
/// turn and calls the same tools from there.
///
/// Either way a call arrives at ``perform(_:arguments:)``, which is the one
/// place that asks the person first when the tool says to, runs it, and writes
/// down what it did. Nothing reaches the app's documents by another road.
@MainActor
public final class ChatEngine {

	public enum Link: Equatable { case looking, missing, connected }

	/// A model somebody can choose, and where it is.
	public struct Choice: Equatable {
		public var provider: Provider
		public var model: ModelInfo
		public var key: String { "\(provider.id)/\(model.id)" }
	}

	/// A call waiting for somebody to say yes.
	public struct Confirmation: Equatable {
		public var question: String
		public var detail: String
	}

	/// A server on the network being linked: the PIN to approve over there.
	public struct Linking: Equatable {
		public var server: String
		public var pin: String?
		public var approveAt: String?
		public var problem: String?
	}

	/// Posted, with the engine as its object, whenever anything here changed.
	public static let changed = Notification.Name("de.rnd7.cuttr.chatChanged")

	public private(set) var link = Link.looking
	public private(set) var choices: [Choice] = []
	/// Why nobody answers, when there is somebody who should.
	public private(set) var problem: String?
	public private(set) var conversation: Conversation
	/// What is happening right now, in a word or two.
	public private(set) var activity: String?
	public private(set) var confirmation: Confirmation?
	public private(set) var linking: Linking?
	/// Messages typed while an answer was being written, sent when it is done.
	public private(set) var queue: [String] = []

	public var isWorking: Bool { turn != nil }

	/// Called with an address and a token once a server has been linked, to be
	/// written into the settings.
	public var keepServer: ((_ url: String, _ token: String) -> Void)?

	private let host: ChatToolHost
	private let store: ChatStore?
	private let settings: () -> ProviderSettings
	private let discoveryFile: URL
	private let session: URLSession?
	private lazy var mcp = MCPServer(
		tools: { [weak self] in self?.host.tools ?? [] },
		call: { [weak self] name, arguments in
			guard let self, self.isWorking else {
				return .failure("No conversation is running in cuttr.")
			}
			return await self.perform(name, arguments: arguments)
		})

	private var turn: Task<Void, Never>?
	private var job: (client: ChatClient, id: String)?
	private var decision: CheckedContinuation<Bool, Never>?
	private var lastCall: Task<ToolResult, Never>?
	private var linkTask: Task<Void, Never>?

	/// How many times a model may go round asking for tools before the turn is
	/// called off. A model that has not finished in this many is not going to.
	static let rounds = 24

	public init(host: ChatToolHost, store: ChatStore?,
	            settings: @escaping () -> ProviderSettings,
	            discoveryFile: URL = Connector.discoveryFile(),
	            session: URLSession? = nil) {
		self.host = host
		self.store = store
		self.settings = settings
		self.discoveryFile = discoveryFile
		self.session = session
		conversation = store?.load() ?? Conversation()
	}

	private func changedNow() {
		NotificationCenter.default.post(name: Self.changed, object: self)
	}

	// MARK: - Who answers

	/// The model in use: the one chosen while it is still offered, else the
	/// first there is — without forgetting the choice, so a connector that was
	/// off for a morning does not quietly change what somebody picked.
	public var chosen: Choice? {
		choices.first { $0.key == conversation.model } ?? choices.first
	}

	public func choose(_ key: String) {
		conversation.model = key
		store?.save(conversation)
		changedNow()
	}

	/// Looks for providers and asks each what it offers.
	public func refresh() async {
		let providers = Providers.find(settings: settings(), discoveryFile: discoveryFile)
		var found: [Choice] = []
		var trouble: String?
		for provider in providers {
			do {
				for model in try await provider.client(session: session).models()
				where !model.isAgent || provider.runsAgents {
					found.append(Choice(provider: provider, model: model))
				}
			} catch {
				trouble = trouble ?? "\(provider.name): \(ChatError.from(error).localizedDescription)"
			}
		}
		let next: Link = found.isEmpty ? .missing : .connected
		let nextProblem = found.isEmpty ? trouble : nil
		guard found != choices || next != link || nextProblem != problem else { return }
		choices = found
		link = next
		problem = nextProblem
		changedNow()
	}

	// MARK: - Linking a server

	/// Asks a server on the network for a PIN and waits for it to be approved.
	public func link(to server: String) {
		linkTask?.cancel()
		linking = Linking(server: server)
		changedNow()
		linkTask = Task { [weak self] in
			guard let self, let root = URL(string: server) else { return }
			let client = ChatClient(root: root, token: nil, isConnector: true, session: self.session)
			do {
				let offer = try await client.startLink(name: "cuttr on \(Host.current().localizedName ?? "a Mac")")
				self.linking = Linking(server: server, pin: offer.pin, approveAt: offer.approveAt)
				self.changedNow()
				while !Task.isCancelled {
					try await Task.sleep(nanoseconds: UInt64(max(1, offer.interval) * 1_000_000_000))
					switch await client.pollLink(offer) {
					case .waiting: continue
					case .token(let token):
						self.keepServer?(server, token)
						self.linking = nil
						self.changedNow()
						await self.refresh()
						return
					case .refused(let why):
						self.linking = Linking(server: server, problem: why)
						self.changedNow()
						return
					}
				}
			} catch is CancellationError {
			} catch {
				self.linking = Linking(server: server, problem: ChatError.from(error).localizedDescription)
				self.changedNow()
			}
		}
	}

	public func cancelLinking() {
		linkTask?.cancel()
		linkTask = nil
		linking = nil
		changedNow()
	}

	// MARK: - Talking

	/// Sends a message — or, while an answer is being written, puts it in the
	/// queue behind that answer.
	public func send(_ text: String) {
		let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		guard turn == nil else {
			queue.append(text)
			changedNow()
			return
		}
		guard let choice = chosen else { return }
		conversation.entries.append(ChatEntry(role: .user, text: text))
		conversation.entries.append(ChatEntry(role: .assistant, text: "", status: .working))
		activity = "Thinking…"
		turn = Task { [weak self] in await self?.run(choice, text) }
		changedNow()
	}

	public func unqueue(_ index: Int) {
		guard queue.indices.contains(index) else { return }
		queue.remove(at: index)
		changedNow()
	}

	/// Stops the answer being written. What it already did stays done — each
	/// step is in the document's undo stack, which is the way back.
	public func stop() {
		guard let turn else { return }
		turn.cancel()
		if let job {
			Task { await job.client.cancel(job: job.id) }
		}
		decide(false)
	}

	/// Empties the conversation and starts a new one.
	public func clear() {
		stop()
		queue = []
		let model = conversation.model
		conversation = Conversation()
		conversation.model = model
		store?.save(conversation)
		changedNow()
	}

	/// Answers the question a tool call is waiting on.
	public func decide(_ allow: Bool) {
		guard let decision else { return }
		self.decision = nil
		decision.resume(returning: allow)
	}

	// MARK: - A turn

	private var answering: Int? {
		guard let last = conversation.entries.indices.last,
		      conversation.entries[last].role == .assistant else { return nil }
		return last
	}

	private func run(_ choice: Choice, _ text: String) async {
		var status = ChatEntry.Status.done
		var why: String?
		do {
			if choice.model.isAgent {
				try await runAgent(choice, text)
			} else {
				try await runModel(choice, text)
			}
			try Task.checkCancellation()
		} catch {
			// A stopped request surfaces as whatever the layer underneath
			// throws when its task goes away; the task knowing it was
			// cancelled is the thing to go by.
			if Task.isCancelled || error is CancellationError {
				status = .stopped
			} else {
				status = .failed
				why = ChatError.from(error).localizedDescription
			}
		}
		if let index = answering {
			conversation.entries[index].status = status
			conversation.entries[index].problem = why
			for tool in conversation.entries[index].tools.indices
			where [.asking, .running].contains(conversation.entries[index].tools[tool].state) {
				conversation.entries[index].tools[tool].state = .failed
			}
		}
		turn = nil
		job = nil
		activity = nil
		confirmation = nil
		store?.save(conversation)
		changedNow()
		// The queue goes on after an answer that finished. After one that was
		// stopped or failed it waits: whatever was typed next was typed
		// expecting the answer before it.
		if status == .done, !queue.isEmpty {
			send(queue.removeFirst())
		}
	}

	/// The conversation so far as the model is told it: the instructions, what
	/// was said, and the new message under a line saying what is on screen.
	private func messages(ending text: String) -> [JSONObject] {
		var out: [JSONObject] = [["role": "system", "content": host.instructions]]
		for entry in conversation.entries.dropLast(2).suffix(20) {
			var said = entry.text
			if !entry.tools.isEmpty {
				said += "\n[tools used: \(entry.tools.map(\.name).joined(separator: ", "))]"
			}
			guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
			out.append(["role": entry.role.rawValue, "content": said])
		}
		out.append(["role": "user", "content": "[\(host.context())]\n\n\(text)"])
		return out
	}

	private func say(_ text: String) {
		guard let index = answering else { return }
		conversation.entries[index].text = text
		changedNow()
	}

	private func runModel(_ choice: Choice, _ text: String) async throws {
		let client = choice.provider.client(session: session)
		var messages = messages(ending: text)
		let tools = host.tools.map(\.openAI)
		var before = ""
		for _ in 0..<Self.rounds {
			activity = "Thinking…"
			changedNow()
			var answer = ChatAPI.Answer()
			let stream = try await client.chat([
				"model": choice.model.id, "messages": messages, "tools": tools,
			])
			for try await data in stream {
				switch answer.apply(data) {
				case .text:
					activity = nil
					say(before + answer.text)
				case .calls:
					activity = "Working…"
					changedNow()
				case .reasoning, .nothing:
					break
				}
				if answer.done { break }
			}
			try Task.checkCancellation()
			if let error = answer.error { throw ChatError.inStream(error) }
			guard !answer.calls.isEmpty else {
				if !answer.done, answer.finish == nil { throw ChatError.brokeOff }
				return
			}
			var said: JSONObject = [
				"role": "assistant",
				"content": answer.text.isEmpty ? NSNull() : answer.text as Any,
				"tool_calls": answer.calls.map { call in
					["id": call.id, "type": "function",
					 "function": ["name": call.name,
					              "arguments": call.arguments.isEmpty ? "{}" : call.arguments] as JSONObject,
					] as JSONObject
				},
			]
			if answer.text.isEmpty { said["content"] = NSNull() }
			messages.append(said)
			for call in answer.calls {
				let result: ToolResult
				if let arguments = JSON.object(call.arguments.isEmpty ? "{}" : call.arguments) {
					result = await perform(call.name, arguments: arguments)
				} else {
					result = .failure("The arguments were not a JSON object.")
				}
				try Task.checkCancellation()
				// A whole take file is a few thousand characters; twelve thousand
				// is room for one and a guard against a result that would push
				// the conversation itself out of the model's window.
				messages.append(["role": "tool", "tool_call_id": call.id,
				                 "content": String(result.text.prefix(12_000))])
			}
			if !answer.text.isEmpty { before += answer.text + "\n\n" }
		}
		throw ChatError.refused("it did not finish in \(Self.rounds) steps")
	}

	private func runAgent(_ choice: Choice, _ text: String) async throws {
		let client = choice.provider.client(session: session)
		let address = try await mcp.start()
		let request: JSONObject = [
			"model": choice.model.id,
			"messages": messages(ending: text),
			"session": "cuttr:\(conversation.id)",
			"fresh": !conversation.started,
			"mcp": [[
				"name": "cuttr", "type": "http", "url": address.absoluteString,
				"headers": ["Authorization": "Bearer \(mcp.token)"],
			] as JSONObject],
		]
		// Listening before asking, so nothing the job says first is missed.
		var events = try await client.events()
		let id = try await client.submit(request)
		job = (client, id)
		conversation.started = true

		var heard = Data()
		var reopened = 0
		listening: while true {
			do {
				for try await data in events {
					guard let event = ChatAPI.jobEvent(data, job: id) else { continue }
					switch event {
					case .text(let piece, let at):
						var bytes = Data(piece.utf8)
						if let at {
							// Seen already, or the tail of something seen in part.
							if at < heard.count { bytes = bytes.dropFirst(heard.count - at) }
							// A hole: the job's own text at the end fills it.
							if at > heard.count { bytes = Data() }
						}
						guard !bytes.isEmpty else { continue }
						heard.append(bytes)
						activity = nil
						say(String(decoding: heard, as: UTF8.self))
					case .status(let line):
						activity = line.isEmpty ? activity : line
						changedNow()
					case .state(let state):
						if ChatAPI.jobFinished(state) { break listening }
					case .other:
						break
					}
				}
			} catch {
				if Task.isCancelled { throw error }
			}
			try Task.checkCancellation()
			// The server ends the stream when its workers change. Listen again,
			// unless the job finished while nobody was.
			if let state = (try? await client.job(id))?["state"] as? String,
			   ChatAPI.jobFinished(state) { break }
			reopened += 1
			guard reopened <= 5 else { throw ChatError.brokeOff }
			events = try await client.events()
		}
		// The job as the connector has it is the answer; the stream was the
		// view of it being written.
		let finished = try await client.job(id)
		switch finished["state"] as? String {
		case "failed": throw ChatError.refused(finished["error"] as? String ?? "failed")
		case "canceled": throw CancellationError()
		default:
			if let whole = finished["text"] as? String, !whole.isEmpty { say(whole) }
		}
	}

	// MARK: - A tool call

	/// Runs one call for the answer being written, asking first when the tool
	/// says to. One at a time: an agent may send two at once, and two questions
	/// on screen with one pair of buttons is a question about which was meant.
	func perform(_ name: String, arguments: JSONObject) async -> ToolResult {
		let before = lastCall
		let text = JSON.text(arguments)
		let task = Task { @MainActor [weak self] () -> ToolResult in
			_ = await before?.value
			guard let self else { return .failure("cuttr has gone.") }
			return await self.performNow(name, arguments: JSON.object(text) ?? [:])
		}
		lastCall = task
		return await task.value
	}

	private func performNow(_ name: String, arguments: JSONObject) async -> ToolResult {
		guard let entry = answering, turn != nil, !(turn?.isCancelled ?? true) else {
			return .failure("The conversation was stopped.")
		}
		conversation.entries[entry].tools.append(
			ChatEntry.Tool(name: name, arguments: JSON.text(arguments)))
		let index = conversation.entries[entry].tools.count - 1
		func update(_ change: (inout ChatEntry.Tool) -> Void) {
			guard conversation.entries.indices.contains(entry),
			      conversation.entries[entry].tools.indices.contains(index) else { return }
			change(&conversation.entries[entry].tools[index])
			changedNow()
		}

		if let question = host.question(before: name, arguments: arguments) {
			update { $0.state = .asking; $0.summary = question }
			confirmation = Confirmation(question: question, detail: JSON.text(arguments, pretty: true))
			changedNow()
			let allowed = await withCheckedContinuation { decision = $0 }
			confirmation = nil
			guard allowed else {
				update { $0.state = .declined; $0.summary = "Declined: \(question)" }
				return .failure("The user declined this. Do not try it again — ask what they would like instead.")
			}
		}
		update { $0.state = .running }
		activity = "Working…"
		let result = await host.call(name, arguments: arguments)
		update {
			$0.state = result.isError ? .failed : .done
			$0.summary = result.summary
			$0.result = String(result.text.prefix(4000))
		}
		return result
	}
}
