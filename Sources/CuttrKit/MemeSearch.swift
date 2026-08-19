import CoreGraphics
import Foundation

/// The services a meme can be fetched from.
///
/// Two, because the interesting thing about them is not the search — both are a
/// query and a list back — but that both already serve an **mp4** of every item
/// they hold. AVFoundation will not open a GIF as a movie, and converting one
/// is work that buys nothing when the provider has already done it.
public enum MemeProvider: String, Sendable, CaseIterable {
	case giphy, tenor

	public var displayName: String {
		switch self {
		case .giphy: return "GIPHY"
		case .tenor: return "Tenor"
		}
	}

	/// The environment variable the key is read from.
	///
	/// The environment first, because that is where a key belongs: a key in a
	/// repository is a key that has been published, and one in a shell profile
	/// is one machine's business.
	public var environmentVariable: String {
		switch self {
		case .giphy: return "GIPHY_API_KEY"
		case .tenor: return "TENOR_API_KEY"
		}
	}

	/// The block it gets in the settings file. See ``Settings``.
	public var settingsBlock: String { rawValue }

	/// Where to go and get one. Shown when there is none, because a search box
	/// that silently returns nothing is worse than one that explains itself.
	public var keyPage: String {
		switch self {
		case .giphy: return "https://developers.giphy.com/dashboard/"
		case .tenor: return "https://developers.google.com/tenor/guides/quickstart"
		}
	}

	/// The mark the service's terms require to be shown where its results are.
	///
	/// GIPHY asks for "Powered By GIPHY" conspicuously wherever the API is
	/// used; Tenor asks for "Powered By Tenor." while somebody is browsing.
	/// Both are shown under the grid and both are written into the take, so
	/// that the obligation travels with the material rather than staying in the
	/// window where it was downloaded.
	public var attribution: String {
		switch self {
		case .giphy: return "Powered By GIPHY"
		case .tenor: return "Powered By Tenor."
		}
	}
}

/// One thing a search found.
public struct MemeResult: Sendable, Equatable, Identifiable {
	public var provider: MemeProvider
	/// The service's own identifier, kept exactly as given: it is what hands
	/// this item back to the service later.
	public var id: String
	public var title: String
	/// The page a person can open to see it where it lives.
	public var page: URL?
	/// The mp4 the provider serves. The whole reason these two services are
	/// the ones supported.
	public var video: URL
	/// A still for the grid, if the service offers one.
	public var preview: URL?
	public var size: CGSize
	/// What the service says it runs for, when it says. Only Tenor does, and
	/// the file itself is asked once it has been downloaded anyway.
	public var duration: Double?

	public init(provider: MemeProvider, id: String, title: String, page: URL?, video: URL,
	            preview: URL? = nil, size: CGSize = .zero, duration: Double? = nil) {
		self.provider = provider
		self.id = id
		self.title = title
		self.page = page
		self.video = video
		self.preview = preview
		self.size = size
		self.duration = duration
	}
}

/// What went wrong looking for one.
///
/// Four separate cases rather than one "search failed", because they are four
/// separate things for somebody to do: get a key, plug the machine in, check
/// the key they have, or wait. A single message covering all four tells nobody
/// which of the four they are in.
public enum MemeError: LocalizedError, Equatable {
	case noKey(MemeProvider)
	case offline
	case keyRejected(MemeProvider, String?)
	case tooManyRequests(MemeProvider)
	case providerDown(MemeProvider, String)
	case unreadable(MemeProvider)
	case noVideo(String)

	public var errorDescription: String? {
		switch self {
		case .noKey(let provider):
			// Where it looked, what to put there, and where to get one. All
			// three, because "no API key" on its own is a dead end.
			return "No \(provider.displayName) key. Put one in "
				+ "\(SettingsFile.url().path) under `\(provider.settingsBlock): key:` — "
				+ "in Settings (⌘,) or in the file — or set \(provider.environmentVariable) "
				+ "in the environment. Keys are free at \(provider.keyPage)"
		case .offline:
			return "No network. Searching needs one; the memes already downloaded "
				+ "are files like any other and still work."
		case .keyRejected(let provider, let message):
			return "\(provider.displayName) refused the key\(message.map { ": \($0)" } ?? ".") "
				+ "Check it at \(provider.keyPage)"
		case .tooManyRequests(let provider):
			return "\(provider.displayName) is rate-limiting this key. Wait a minute and try again."
		case .providerDown(let provider, let message):
			return "\(provider.displayName) is not answering: \(message)"
		case .unreadable(let provider):
			return "\(provider.displayName) answered with something this version cannot read."
		case .noVideo(let title):
			return "\(title.isEmpty ? "That one" : title) has no mp4 to download."
		}
	}
}

/// Where the keys come from.
///
/// Two places and no others: the environment, and ``Settings`` — the settings
/// file, which is the one a person can look at. The environment wins so that
/// `GIPHY_API_KEY=… make dev` is a one-off nobody has to undo, and the file is
/// what makes it work at all for an app launched from the Dock, which inherits
/// no shell and so has never seen anybody's `export`.
///
/// Nothing here writes a key anywhere else, and nothing in this repository has
/// ever held one.
public enum MemeKeys {

	public static func key(
		for provider: MemeProvider,
		environment: [String: String] = ProcessInfo.processInfo.environment,
		settings: Settings? = nil
	) -> String? {
		if let fromEnvironment = environment[provider.environmentVariable]?
			.trimmingCharacters(in: .whitespacesAndNewlines), !fromEnvironment.isEmpty {
			return fromEnvironment
		}
		// Read on every ask rather than cached, so a key pasted into the
		// settings sheet — or typed into the file in another window — is in
		// effect on the next search and not after a relaunch.
		let file = settings ?? (try? SettingsFile.read()) ?? Settings()
		return file.key(for: provider.settingsBlock)
	}

	/// A provider that can actually be searched now, so the panel opens on one
	/// that works rather than on one that will ask for a key.
	public static func firstUsable(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		settings: Settings? = nil
	) -> MemeProvider {
		let file = settings ?? (try? SettingsFile.read()) ?? Settings()
		return MemeProvider.allCases
			.first { key(for: $0, environment: environment, settings: file) != nil } ?? .giphy
	}
}

/// Asking a provider what it has.
public enum MemeSearch {

	/// How the bytes are fetched. A closure so that everything above it can be
	/// tested without a network: the parsing, the classifying of a refusal, and
	/// the message somebody sees when the machine is unplugged are the parts
	/// with right answers, and none of them should need the internet to check.
	public typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

	public static let live: Fetch = { url in
		var request = URLRequest(url: url)
		// Fifteen seconds is a search box, not a download: waiting a minute for
		// a list of cats is the sort of thing that makes a window look hung.
		request.timeoutInterval = 15
		let (data, response) = try await URLSession.shared.data(for: request)
		return (data, response)
	}

	public static let resultsPerSearch = 24

	// MARK: - The request

	public static func url(for provider: MemeProvider, query: String, key: String,
	                       limit: Int = resultsPerSearch) -> URL? {
		var components: URLComponents
		var items: [URLQueryItem]
		switch provider {
		case .giphy:
			components = URLComponents(string: "https://api.giphy.com/v1/gifs/search")!
			items = [
				URLQueryItem(name: "api_key", value: key),
				URLQueryItem(name: "q", value: query),
				URLQueryItem(name: "limit", value: String(limit)),
				// Not "all", which includes the rating nobody wants to explain
				// to the room. Anything stricter throws away most of what a
				// meme search is for.
				URLQueryItem(name: "rating", value: "pg-13"),
			]
		case .tenor:
			components = URLComponents(string: "https://tenor.googleapis.com/v2/search")!
			items = [
				URLQueryItem(name: "key", value: key),
				URLQueryItem(name: "q", value: query),
				URLQueryItem(name: "limit", value: String(limit)),
				// Tenor prunes `media_formats` to what is asked for, which is
				// worth doing: the full set is a dozen renditions per result
				// and this needs two of them.
				URLQueryItem(name: "media_filter", value: "mp4,tinygif,preview"),
				// Identifies the app to Tenor, as its docs ask.
				URLQueryItem(name: "client_key", value: "de.rnd7.cuttr"),
			]
		}
		components.queryItems = items
		return components.url
	}

	// MARK: - Doing it

	public static func search(
		_ query: String, provider: MemeProvider, key: String, fetch: Fetch = live
	) async throws -> [MemeResult] {
		let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !wanted.isEmpty else { return [] }
		guard !key.isEmpty else { throw MemeError.noKey(provider) }
		guard let url = url(for: provider, query: wanted, key: key) else {
			throw MemeError.unreadable(provider)
		}

		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await fetch(url)
		} catch let error as URLError {
			// The machine being off the network is not the provider being
			// down, and saying so saves somebody checking a service that is
			// perfectly well.
			switch error.code {
			case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
			     .cannotConnectToHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
			     .dataNotAllowed:
				throw MemeError.offline
			default:
				throw MemeError.providerDown(provider, error.localizedDescription)
			}
		}

		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			throw failure(provider, status: http.statusCode, body: data)
		}
		return try parse(data, from: provider)
	}

	/// What a refusal means.
	///
	/// The two services disagree about which code a bad key is, which is the
	/// whole reason this is a function rather than a switch on 401. GIPHY says
	/// 401 or 403; Tenor is a Google API and says **400 INVALID_ARGUMENT** with
	/// "API key not valid" in the message. Reporting Tenor's as "the provider
	/// sent a bad request" would send somebody looking at their search term.
	static func failure(_ provider: MemeProvider, status: Int, body: Data) -> MemeError {
		let message = self.message(in: body)
		switch status {
		case 401, 403:
			return .keyRejected(provider, message)
		case 400:
			let looksLikeTheKey = (message ?? "").lowercased().contains("key")
			return looksLikeTheKey || provider == .tenor
				? .keyRejected(provider, message)
				: .providerDown(provider, message ?? "bad request")
		case 429:
			return .tooManyRequests(provider)
		default:
			return .providerDown(provider, message ?? "HTTP \(status)")
		}
	}

	/// Whatever the body says went wrong, in either service's spelling.
	///
	/// Neither publishes an error body worth relying on, so this reads the
	/// three shapes both are known to send and gives up quietly rather than
	/// turning an unexpected body into a second failure.
	static func message(in body: Data) -> String? {
		guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
			return nil
		}
		if let error = object["error"] as? [String: Any],
		   let message = error["message"] as? String { return message }
		if let meta = object["meta"] as? [String: Any],
		   let message = meta["msg"] as? String { return message }
		if let message = object["message"] as? String { return message }
		return nil
	}

	// MARK: - Reading the answer

	/// Two parsers rather than one decoder, and deliberately.
	///
	/// GIPHY writes its numbers as strings — `"width": "480"` — and Tenor
	/// writes them as numbers; GIPHY nests renditions under `images` and Tenor
	/// under `media_formats`; one has renditions with no `url` at all. A shared
	/// `Codable` shape for the two would be a pile of optional coding keys that
	/// silently decodes to nothing the day either changes.
	public static func parse(_ data: Data, from provider: MemeProvider) throws -> [MemeResult] {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw MemeError.unreadable(provider)
		}
		switch provider {
		case .giphy: return parseGiphy(object)
		case .tenor: return parseTenor(object)
		}
	}

	private static func parseGiphy(_ object: [String: Any]) -> [MemeResult] {
		guard let data = object["data"] as? [[String: Any]] else { return [] }
		return data.compactMap { item in
			guard let id = item["id"] as? String else { return nil }
			let images = item["images"] as? [String: Any] ?? [:]
			func rendition(_ name: String) -> [String: Any]? { images[name] as? [String: Any] }
			// Best first: the original is what the uploader gave, and a meme is
			// a couple of hundred kilobytes either way. `looping` and
			// `downsized_small` carry an mp4 and no `url` at all, which is why
			// the mp4 is looked for by name rather than by taking a rendition
			// and hoping.
			let mp4 = ["original", "fixed_height", "downsized_small", "looping", "preview"]
				.lazy.compactMap { rendition($0)?["mp4"] as? String }
				.first.flatMap(URL.init(string:))
			guard let mp4 else { return nil }
			let still = ["fixed_width_small_still", "fixed_height_small_still",
			             "preview_gif", "original_still"]
				.lazy.compactMap { rendition($0)?["url"] as? String }
				.first.flatMap(URL.init(string:))
			// Strings, in this API. `Int("480")`, not `as? Int`.
			func number(_ value: Any?) -> CGFloat {
				if let text = value as? String, let n = Double(text) { return CGFloat(n) }
				if let n = value as? Double { return CGFloat(n) }
				if let n = value as? Int { return CGFloat(n) }
				return 0
			}
			let original = rendition("original") ?? [:]
			let title = (item["title"] as? String) ?? (item["alt_text"] as? String) ?? ""
			return MemeResult(
				provider: .giphy, id: id,
				title: title.trimmingCharacters(in: .whitespaces),
				page: (item["url"] as? String).flatMap(URL.init(string:)),
				video: mp4, preview: still,
				size: CGSize(width: number(original["width"]), height: number(original["height"])))
		}
	}

	private static func parseTenor(_ object: [String: Any]) -> [MemeResult] {
		guard let results = object["results"] as? [[String: Any]] else { return [] }
		return results.compactMap { item in
			guard let id = item["id"] as? String else { return nil }
			let formats = item["media_formats"] as? [String: Any] ?? [:]
			func format(_ name: String) -> [String: Any]? { formats[name] as? [String: Any] }
			let mp4Format = ["mp4", "loopedmp4", "tinymp4", "nanomp4"]
				.lazy.compactMap { format($0) }.first
			guard let mp4Format,
			      let video = (mp4Format["url"] as? String).flatMap(URL.init(string:))
			else { return nil }
			let still = ["preview", "tinygif", "nanogif", "gif"]
				.lazy.compactMap { format($0)?["url"] as? String }
				.first.flatMap(URL.init(string:))
			let dims = (mp4Format["dims"] as? [Any])?.compactMap { $0 as? Int } ?? []
			// `title` is usually empty on Tenor and `content_description` is
			// the sentence a person would recognise it by, which is what the
			// grid shows and what the clip ends up named.
			let title = [(item["content_description"] as? String), (item["title"] as? String)]
				.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
				.first { !$0.isEmpty } ?? ""
			return MemeResult(
				provider: .tenor, id: id, title: title,
				page: (item["itemurl"] as? String ?? item["url"] as? String)
					.flatMap(URL.init(string:)),
				video: video, preview: still,
				size: CGSize(width: dims.count == 2 ? CGFloat(dims[0]) : 0,
				             height: dims.count == 2 ? CGFloat(dims[1]) : 0),
				duration: mp4Format["duration"] as? Double)
		}
	}
}

public extension TakeSource {

	/// Is this one of the meme services?
	///
	/// The question the library asks to decide which section a take belongs
	/// under. Answered from the take's own `source:` block and not from the
	/// folder the file happens to sit in — a guess from the path is right until
	/// somebody drags the file somewhere tidier, and then the meme quietly
	/// stops being a meme.
	var isMeme: Bool { MemeProvider(rawValue: provider) != nil }
}
