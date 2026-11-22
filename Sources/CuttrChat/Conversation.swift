import Foundation

/// One turn of the conversation, as it is shown and as it is kept.
public struct ChatEntry: Codable, Equatable, Sendable {
	public enum Role: String, Codable, Sendable { case user, assistant }
	public enum Status: String, Codable, Sendable { case working, done, stopped, failed }

	/// One thing the assistant did in the app while answering.
	public struct Tool: Codable, Equatable, Sendable {
		public enum State: String, Codable, Sendable { case asking, running, done, failed, declined }
		public var name: String
		/// The arguments, as JSON text.
		public var arguments: String
		/// What it did, in a line.
		public var summary = ""
		public var result = ""
		public var state = State.running

		public init(name: String, arguments: String, summary: String = "", result: String = "",
		            state: State = .running) {
			self.name = name
			self.arguments = arguments
			self.summary = summary
			self.result = result
			self.state = state
		}
	}

	public var role: Role
	public var text: String
	public var tools: [Tool] = []
	public var status = Status.done
	/// Why it failed, when it did.
	public var problem: String?

	public init(role: Role, text: String, status: Status = .done) {
		self.role = role
		self.text = text
		self.status = status
	}
}

/// The conversation: what was said, and which agent session it is.
public struct Conversation: Codable, Equatable, Sendable {
	/// Random, and the key of the agent's own session — Claude Code keeps the
	/// history of a conversation itself, under this name.
	public var id: String
	/// Whether the agent has been spoken to under ``id`` yet. The first turn of
	/// a conversation starts the session afresh; later ones continue it.
	public var started = false
	/// The model chosen, as `provider/model`.
	public var model: String?
	public var entries: [ChatEntry] = []

	public init() {
		var generator = SystemRandomNumberGenerator()
		id = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
			.joined()
	}
}

/// Where the conversation is kept: one file, on this computer.
///
/// Not in the project. A project is something people share — it lives in a
/// repository and is pushed — and what somebody typed to an assistant on the
/// way to a cut is not part of the cut. So it sits beside the settings, readable
/// by its owner only, and goes nowhere.
public struct ChatStore: Sendable {
	public var file: URL

	/// How many entries are kept. A conversation is a working aid, not an
	/// archive, and the file is read on every launch.
	public static let limit = 200

	public init(file: URL) { self.file = file }

	public func load() -> Conversation {
		guard let data = try? Data(contentsOf: file),
		      var kept = try? JSONDecoder().decode(Conversation.self, from: data)
		else { return Conversation() }
		// Nothing is working after a restart, whatever the file says: an answer
		// that was being written when the app quit was stopped by the quitting.
		for index in kept.entries.indices where kept.entries[index].status == .working {
			kept.entries[index].status = .stopped
			for tool in kept.entries[index].tools.indices
			where [.asking, .running].contains(kept.entries[index].tools[tool].state) {
				kept.entries[index].tools[tool].state = .failed
			}
		}
		return kept
	}

	public func save(_ conversation: Conversation) {
		var kept = conversation
		kept.entries = Array(kept.entries.suffix(Self.limit))
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		guard let data = try? encoder.encode(kept) else { return }
		let manager = FileManager.default
		try? manager.createDirectory(at: file.deletingLastPathComponent(),
		                             withIntermediateDirectories: true)
		try? data.write(to: file, options: .atomic)
		try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
	}
}
