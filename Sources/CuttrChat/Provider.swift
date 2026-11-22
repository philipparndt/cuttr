import Foundation
import Network

/// Somewhere an answer can come from.
public struct Provider: Equatable, Sendable {
	public enum Kind: String, Sendable {
		/// ai-connector on this computer, found by its discovery file.
		case local
		/// An ai-connector server elsewhere, linked with a PIN.
		case server
		/// Anything that speaks the OpenAI API: OpenRouter, OpenAI, Ollama,
		/// LM Studio.
		case openAI
	}

	public var id: String
	public var name: String
	public var kind: Kind
	public var root: URL
	public var token: String?

	public init(id: String, name: String, kind: Kind, root: URL, token: String?) {
		self.id = id
		self.name = name
		self.kind = kind
		self.root = root
		self.token = token
	}

	/// Whether Claude Code can be asked to work here.
	///
	/// Only on this computer. An agent reaches the app through a server the app
	/// opens on the loopback interface, and a Claude Code running on another
	/// machine has no way to that — offering it there would be offering
	/// something that fails on its first tool call.
	public var runsAgents: Bool { kind == .local }

	public func client(session: URLSession? = nil) -> ChatClient {
		ChatClient(root: root, token: token, isConnector: kind != .openAI, session: session)
	}
}

/// What the settings file says about the assistant, as this module needs it.
///
/// Passed in rather than read here: the settings file belongs to the model
/// layer, and this target knows nothing of it.
public struct ProviderSettings: Equatable, Sendable {
	/// `ai-connector:` — a server linked by PIN. `url:` and `key:`.
	public var serverURL: String?
	public var serverToken: String?
	/// `ai:` — an OpenAI-compatible endpoint. `url:` and, where one is needed,
	/// `key:`.
	public var openAIURL: String?
	public var openAIKey: String?

	public init(serverURL: String? = nil, serverToken: String? = nil,
	            openAIURL: String? = nil, openAIKey: String? = nil) {
		self.serverURL = serverURL
		self.serverToken = serverToken
		self.openAIURL = openAIURL
		self.openAIKey = openAIKey
	}
}

public enum Providers {

	/// Every provider there is to ask, the one on this computer first.
	///
	/// Finding one is not the same as its answering: a discovery file left by a
	/// crash names a port nobody listens on. Whether a provider is *there* is
	/// what asking it for its models says.
	public static func find(
		settings: ProviderSettings,
		discoveryFile: URL = Connector.discoveryFile()
	) -> [Provider] {
		var out: [Provider] = []
		if let found = try? Connector.discovery(at: discoveryFile), let url = URL(string: found.url) {
			out.append(Provider(id: "local", name: "This Mac", kind: .local, root: url, token: found.token))
		}
		if let text = settings.serverURL, let url = URL(string: text), url.host != nil,
		   let token = settings.serverToken {
			out.append(Provider(id: "server", name: url.host ?? text, kind: .server, root: url, token: token))
		}
		if let text = settings.openAIURL, let url = URL(string: text), url.host != nil {
			out.append(Provider(id: "openai", name: url.host ?? text, kind: .openAI,
			                    root: url, token: settings.openAIKey))
		}
		return out
	}
}

/// ai-connector servers on the network, by Bonjour.
///
/// A server announces `_ai-connector._tcp`. One behind an ingress says its
/// public address in the TXT record's `url`, and that wins over the announced
/// host and port — those are the node's plain port, not the name people use.
public final class ServerBrowser: @unchecked Sendable {

	public struct Found: Equatable, Sendable {
		public var name: String
		public var url: String
	}

	public static let service = "_ai-connector._tcp"

	private let browser: NWBrowser
	private let queue = DispatchQueue(label: "de.rnd7.cuttr.chat.browse")
	private var connections: [NWConnection] = []
	private var found: [Found] = []
	private let onChange: @Sendable ([Found]) -> Void

	/// `onChange` is called on the main queue with everything found so far.
	public init(onChange: @escaping @Sendable ([Found]) -> Void) {
		self.onChange = onChange
		let parameters = NWParameters()
		parameters.includePeerToPeer = false
		browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.service, domain: "local."),
		                    using: parameters)
	}

	public func start() {
		browser.browseResultsChangedHandler = { [weak self] results, _ in
			self?.queue.async { self?.took(results) }
		}
		browser.start(queue: queue)
	}

	public func stop() {
		browser.cancel()
		queue.async { [weak self] in
			self?.connections.forEach { $0.cancel() }
			self?.connections = []
		}
	}

	private func took(_ results: Set<NWBrowser.Result>) {
		connections.forEach { $0.cancel() }
		connections = []
		found = []
		publish()
		for result in results {
			guard case .service(let name, _, _, _) = result.endpoint else { continue }
			if case .bonjour(let record) = result.metadata, let url = record["url"],
			   !url.trimmingCharacters(in: .whitespaces).isEmpty {
				add(Found(name: name, url: Self.trimmed(url)))
				continue
			}
			// No address in the record, so ask the network where it is: a
			// connection to the service resolves it, and the path it settles
			// on names the host and the port.
			let connection = NWConnection(to: result.endpoint, using: .tcp)
			connection.stateUpdateHandler = { [weak self, weak connection] state in
				guard case .ready = state, let connection,
				      case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint
				else { return }
				self?.add(Found(name: name, url: Self.url(host: host, port: port.rawValue)))
				connection.cancel()
			}
			connections.append(connection)
			connection.start(queue: queue)
		}
	}

	private func add(_ server: Found) {
		guard !found.contains(where: { $0.url == server.url }) else { return }
		found.append(server)
		publish()
	}

	private func publish() {
		let all = found
		let tell = onChange
		DispatchQueue.main.async { tell(all) }
	}

	static func trimmed(_ url: String) -> String {
		var out = url.trimmingCharacters(in: .whitespaces)
		while out.hasSuffix("/") { out.removeLast() }
		return out
	}

	/// `http://192.168.1.20:8485`. An IPv6 address goes in brackets and loses
	/// the interface it was scoped to, which means nothing in a URL.
	static func url(host: NWEndpoint.Host, port: UInt16) -> String {
		switch host {
		case .ipv4(let address): return "http://\(address):\(port)"
		case .ipv6(let address):
			let text = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
			return "http://[\(text)]:\(port)"
		case .name(let name, _):
			return "http://\(name.hasSuffix(".") ? String(name.dropLast()) : name):\(port)"
		@unknown default: return "http://\(host):\(port)"
		}
	}
}
