import Foundation
import Yams

/// What the program remembers between sessions, as text.
///
/// `~/.config/cuttr/config.yaml`, and it is a file somebody can open, read and
/// edit — which is the same promise the take file and the project file make. A
/// preferences database would have been fewer lines and would have made "I set
/// the key and it did not take" a question with no way to answer it: you cannot
/// `cat` a plist somebody wrote with `defaults write` and see what the app
/// actually believes.
///
/// The environment still beats it. `GIPHY_API_KEY=… make dev` is a one-off that
/// should not require editing anything, and a machine set up once through the
/// environment keeps working. But the environment is not enough on its own: an
/// app launched from Finder or the Dock inherits no shell, so an `export` in a
/// profile is invisible to it — which is exactly the trap this file exists to
/// get out of.
///
/// The shape is a block per thing:
///
/// ```yaml
/// giphy:
///   key: abc123
/// ```
public struct Settings: Sendable, Equatable {

	/// One block. Its `key:`, and whatever else somebody keeps in it.
	public struct Service: Sendable, Equatable {
		public var key: String?
		/// Keys in this block that this version does not use, kept so that
		/// saving from the app does not throw away somebody else's line.
		public var extra: [String: String]

		public init(key: String? = nil, extra: [String: String] = [:]) {
			self.key = key
			self.extra = extra
		}

		public var isEmpty: Bool { (key?.isEmpty ?? true) && extra.isEmpty }
	}

	/// The blocks, by name — `giphy`, `tenor`, and whatever comes next.
	///
	/// A map rather than two fields, because the next service to be supported
	/// should not be a change to this file, and because a block this program
	/// does not know about has to survive being saved.
	public var services: [String: Service]

	/// Top-level keys that are not blocks. Carried through unchanged.
	public var unknownKeys: [String: Any] {
		get { unknown.storage }
		set { unknown = UnknownKeys(storage: newValue) }
	}
	var unknown: UnknownKeys

	public init(services: [String: Service] = [:], unknownKeys: [String: Any] = [:]) {
		self.services = services
		self.unknown = UnknownKeys(storage: unknownKeys)
	}

	public static func == (a: Settings, b: Settings) -> Bool { a.services == b.services }

	public func key(for service: String) -> String? {
		let key = services[service]?.key?.trimmingCharacters(in: .whitespacesAndNewlines)
		return (key?.isEmpty ?? true) ? nil : key
	}

	public mutating func setKey(_ key: String?, for service: String) {
		let cleaned = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		var block = services[service] ?? Service()
		block.key = cleaned.isEmpty ? nil : cleaned
		// A block with nothing left in it goes, rather than sitting in the file
		// as an empty heading that looks like something half-done.
		if block.isEmpty { services.removeValue(forKey: service) } else { services[service] = block }
	}
}

/// Reading and writing the settings file.
public enum SettingsFile {

	/// `$XDG_CONFIG_HOME/cuttr/config.yaml`, or `~/.config/cuttr/config.yaml`.
	///
	/// The XDG variable is honoured because somebody who has set it has said
	/// where their configuration goes, and a program that ignores that is one
	/// more exception to remember.
	public static func url(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		let base: URL
		if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
			base = URL(fileURLWithPath: xdg, isDirectory: true)
		} else {
			base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
				.appendingPathComponent(".config", isDirectory: true)
		}
		return base.appendingPathComponent("cuttr", isDirectory: true)
			.appendingPathComponent("config.yaml")
	}

	/// What is in the file, or nothing when there is no file.
	///
	/// A missing file is not an error — most installations will never have one
	/// — but a file that is there and broken is, because silently reading it as
	/// empty is how somebody comes to believe they have set a key they have not.
	public static func read(at url: URL = url()) throws -> Settings {
		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Settings() }
		return try parse(text)
	}

	public static func parse(_ text: String) throws -> Settings {
		let object: Any?
		do { object = try Yams.load(yaml: text) }
		catch { throw SettingsError.yaml(error.localizedDescription) }
		guard let object else { return Settings() }
		guard let root = object as? [String: Any] else { throw SettingsError.notAMapping }

		var services: [String: Settings.Service] = [:]
		var unknown: [String: Any] = [:]
		for (name, value) in root {
			guard var block = value as? [String: Any] else { unknown[name] = value; continue }
			let key = (block.removeValue(forKey: "key") as? String)?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			var extra: [String: String] = [:]
			for (inner, value) in block { extra[inner] = String(describing: value) }
			services[name] = Settings.Service(key: (key?.isEmpty ?? true) ? nil : key, extra: extra)
		}
		return Settings(services: services, unknownKeys: unknown)
	}

	/// Written by hand, for the same reason every other file this program owns
	/// is: a general emitter reorders and requotes, and a settings file that
	/// churns is a settings file nobody will keep in a repository.
	public static func write(_ settings: Settings) -> String {
		var out = "# cuttr settings. Plain text, on purpose — edit it here or in ⌘, .\n"
		for name in settings.services.keys.sorted() {
			let block = settings.services[name]!
			out += "\n\(name):\n"
			if let key = block.key { out += "  key: \(TakeWriter.scalar(key))\n" }
			for inner in block.extra.keys.sorted() {
				out += "  \(inner): \(TakeWriter.scalar(block.extra[inner]!))\n"
			}
		}
		if !settings.unknownKeys.isEmpty {
			out += "\n"
			for key in settings.unknownKeys.keys.sorted() {
				out += (try? Yams.dump(object: [key: settings.unknownKeys[key]!])) ?? ""
			}
		}
		return out
	}

	/// Saves, making the folder if it is not there. A first key pasted into the
	/// app is the usual reason this file comes to exist at all.
	public static func save(_ settings: Settings, to url: URL = url()) throws {
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try write(settings).write(to: url, atomically: true, encoding: .utf8)
	}
}

public enum SettingsError: LocalizedError {
	case notAMapping
	case yaml(String)

	public var errorDescription: String? {
		switch self {
		case .notAMapping:
			return "The settings file's top level should be a list of keys."
		case .yaml(let message):
			return "The settings file is not valid YAML: \(message)"
		}
	}
}
