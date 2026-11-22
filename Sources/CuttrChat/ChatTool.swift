import Foundation

/// One thing the assistant can do in the app.
public struct ToolDefinition: Sendable {
	public var name: String
	public var description: String
	/// A JSON Schema object for the arguments, as JSON text. Text rather than a
	/// dictionary so a definition is a value that can cross threads; it is
	/// parsed where it is sent.
	public var schema: String

	public init(name: String, description: String, schema: String) {
		self.name = name
		self.description = description
		self.schema = schema
	}

	/// Built from the parameters, which is how every tool here is written:
	/// `["time": .string("…")]`, and which of them must be given.
	public init(_ name: String, _ description: String,
	            _ parameters: [(String, Parameter)] = [], required: [String] = []) {
		var properties: JSONObject = [:]
		for (key, parameter) in parameters { properties[key] = parameter.schema }
		let schema: JSONObject = [
			"type": "object", "properties": properties, "required": required,
		]
		self.init(name: name, description: description, schema: JSON.text(schema))
	}

	public struct Parameter: Sendable {
		var type: String
		var description: String

		public static func string(_ description: String) -> Parameter { .init(type: "string", description: description) }
		public static func number(_ description: String) -> Parameter { .init(type: "number", description: description) }
		public static func boolean(_ description: String) -> Parameter { .init(type: "boolean", description: description) }
		public static func strings(_ description: String) -> Parameter { .init(type: "array", description: description) }

		var schema: JSONObject {
			var out: JSONObject = ["type": type, "description": description]
			if type == "array" { out["items"] = ["type": "string"] }
			return out
		}
	}

	var schemaObject: JSONObject { JSON.object(schema) ?? ["type": "object"] }

	/// As an OpenAI function tool.
	var openAI: JSONObject {
		["type": "function",
		 "function": ["name": name, "description": description, "parameters": schemaObject] as JSONObject]
	}

	/// As an MCP tool.
	var mcp: JSONObject {
		["name": name, "description": description, "inputSchema": schemaObject]
	}
}

/// What a tool said.
public struct ToolResult: Equatable, Sendable {
	public var text: String
	public var isError: Bool
	/// One line for the chat: what the call did, in the app's own words.
	public var summary: String

	public init(_ text: String, summary: String? = nil, isError: Bool = false) {
		self.text = text
		self.isError = isError
		self.summary = summary ?? String(text.split(separator: "\n").first ?? "")
	}

	public static func failure(_ text: String) -> ToolResult {
		ToolResult(text, summary: text, isError: true)
	}
}

/// The app, as the assistant sees it.
///
/// The window layer implements this. Everything is on the main actor because
/// everything it touches is: documents, windows, the menu.
@MainActor
public protocol ChatToolHost: AnyObject {
	var tools: [ToolDefinition] { get }

	/// Runs one call. Never throws: what went wrong is the result, because the
	/// model is the one that has to read it and try something else.
	func call(_ name: String, arguments: JSONObject) async -> ToolResult

	/// The question to put to the person before running this call, or `nil`
	/// when it needs none.
	///
	/// Asked at the boundary rather than left to the model's manners. A prompt
	/// can say "ask first" and a model can decide not to; a call that does not
	/// run until somebody has pressed Allow cannot be talked out of it.
	func question(before name: String, arguments: JSONObject) -> String?

	/// One line the model reads before each message: what is on screen now.
	func context() -> String

	/// What the model is told about the app, once, at the head of a
	/// conversation.
	var instructions: String { get }
}
