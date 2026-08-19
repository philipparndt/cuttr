import Foundation
import Testing
@testable import CuttrKit

/// The settings file: read, written, and left alone.
///
/// No key in here is a real one, and none of them touches the real file — every
/// test that writes writes into a temporary folder it makes itself. A test
/// fixture is a place an API key gets committed by accident, so there is not
/// one.
@Suite struct SettingsTests {

	@Test func readsWhatSomebodyWouldTypeByHand() throws {
		let settings = try SettingsFile.parse("""
		giphy:
		  key: abc123
		tenor:
		  key: def456
		""")
		#expect(settings.key(for: "giphy") == "abc123")
		#expect(settings.key(for: "tenor") == "def456")
	}

	@Test func noFileIsNoKeyRatherThanAFailure() throws {
		let missing = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-\(UUID().uuidString)/config.yaml")
		let settings = try SettingsFile.read(at: missing)
		#expect(settings.key(for: "giphy") == nil)
	}

	@Test func aBrokenFileSaysSoRatherThanReadingAsEmpty() {
		// Silently reading nonsense as "no key set" is how somebody comes to
		// believe they have set a key they have not.
		#expect(throws: SettingsError.self) { try SettingsFile.parse("giphy: [1, 2\n") }
	}

	@Test func writingIsStableForTheSameSettings() {
		var settings = Settings()
		settings.setKey("abc123", for: "giphy")
		settings.setKey("def456", for: "tenor")
		#expect(SettingsFile.write(settings) == SettingsFile.write(settings))
	}

	@Test func roundTripsThroughTheFile() throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-settings-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		var settings = Settings()
		settings.setKey("abc123", for: "giphy")
		// The folder does not exist yet: pasting a first key into the sheet is
		// the usual reason the file comes to exist at all.
		let url = folder.appendingPathComponent("cuttr/config.yaml")
		try SettingsFile.save(settings, to: url)
		#expect(try SettingsFile.read(at: url).key(for: "giphy") == "abc123")
	}

	@Test func whatTheAppDoesNotUnderstandSurvivesBeingSaved() throws {
		// Somebody keeping their own notes in this file must not lose them
		// because the app saved a key over the top.
		var settings = try SettingsFile.parse("""
		giphy:
		  key: abc123
		  rating: g
		editor: vim
		""")
		settings.setKey("def456", for: "tenor")
		let written = SettingsFile.write(settings)
		#expect(written.contains("rating: g"))
		#expect(written.contains("editor: vim"))
		#expect(try SettingsFile.parse(written).key(for: "tenor") == "def456")
	}

	@Test func clearingAKeyRemovesTheBlock() {
		var settings = Settings()
		settings.setKey("abc123", for: "giphy")
		settings.setKey("", for: "giphy")
		#expect(!SettingsFile.write(settings).contains("giphy"))
	}

	@Test func xdgSaysWhereItGoes() {
		let path = SettingsFile.url(environment: ["XDG_CONFIG_HOME": "/tmp/somewhere"]).path
		#expect(path == "/tmp/somewhere/cuttr/config.yaml")
		#expect(SettingsFile.url(environment: [:]).path.hasSuffix("/.config/cuttr/config.yaml"))
	}
}
