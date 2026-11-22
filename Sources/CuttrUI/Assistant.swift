import AppKit
import CuttrChat
import CuttrKit

/// The one assistant the application has, and where it keeps its things.
///
/// One conversation for the application rather than one per window: two
/// windows are two views of the same cut, and an assistant that knew in one of
/// them what it had been told in the other would be the exception to explain.
@MainActor
enum Assistant {

	/// Made when it is first asked for, which is when somebody first opens the
	/// panel. A launch that never does opens no socket and reads no file.
	static let engine: ChatEngine = {
		let engine = ChatEngine(
			host: AssistantTools(desk: AppDelegate.shared),
			store: ChatStore(file: folder.appendingPathComponent("chat.json")),
			settings: providerSettings)
		engine.keepServer = keep
		return engine
	}()

	/// Beside the settings file, and for the same reason it is where it is.
	static var folder: URL { SettingsFile.url().deletingLastPathComponent() }

	/// What the settings file says about where an answer can come from.
	///
	/// Two blocks, in the shape every block in that file has:
	///
	/// ```yaml
	/// ai-connector:        # a server linked from the panel
	///   key: aic_…
	///   url: http://studio.local:8485
	/// ai:                  # any OpenAI-compatible address
	///   key: sk-…
	///   url: https://openrouter.ai/api/v1
	/// ```
	///
	/// The connector on this Mac is in neither: it is found by the file it
	/// keeps while it runs, and its token is read from there each time and
	/// stored nowhere.
	static func providerSettings() -> ProviderSettings {
		let settings = (try? SettingsFile.read()) ?? Settings()
		return ProviderSettings(
			serverURL: settings.services["ai-connector"]?.extra["url"],
			serverToken: settings.key(for: "ai-connector"),
			openAIURL: settings.services["ai"]?.extra["url"],
			openAIKey: settings.key(for: "ai"))
	}

	/// Writes a linked server into the settings.
	private static func keep(url: String, token: String) {
		guard var settings = try? SettingsFile.read() else { return }
		var block = settings.services["ai-connector"] ?? Settings.Service()
		block.key = token
		block.extra["url"] = url
		settings.services["ai-connector"] = block
		try? SettingsFile.save(settings)
	}

	/// The line to paste into a terminal, with the script it runs put in place.
	static func setupCommand() -> String {
		let script = (try? Connector.writeSetupScript(into: folder))
			?? folder.appendingPathComponent("ai-setup.sh")
		return Connector.setupCommand(script: script)
	}

	static func makePanel() -> ChatPanel {
		ChatPanel(engine: engine, setupCommand: setupCommand)
	}
}
