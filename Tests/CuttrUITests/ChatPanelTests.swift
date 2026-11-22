import AppKit
import Testing
import CuttrChat
@testable import CuttrKit
@testable import CuttrUI

/// The assistant's column: what it shows for each state the conversation can
/// be in, and what opening it does to the window it is in.
///
/// Built without the network and without anybody's AI. `live: false` keeps a
/// panel from browsing the LAN or polling, and the engine is pointed at a
/// discovery file in a folder made for the test — so "nobody is connected" is a
/// fact about that folder and not about the machine the test runs on.
@MainActor @Suite struct ChatPanelTests {

	private let folder: URL

	init() throws {
		folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-chat-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	}

	private func engine(_ kept: Conversation? = nil) -> ChatEngine {
		let store = ChatStore(file: folder.appendingPathComponent("chat.json"))
		if let kept { store.save(kept) }
		return ChatEngine(host: AssistantTools(desk: nil, menu: { nil }), store: store,
		                  settings: { ProviderSettings() },
		                  discoveryFile: folder.appendingPathComponent("local-ai.json"))
	}

	private func panel(_ engine: ChatEngine) -> ChatPanel {
		let panel = ChatPanel(engine: engine, setupCommand: { "sh /somewhere/ai-setup.sh" }, live: false)
		panel.frame = NSRect(x: 0, y: 0, width: ChatPanel.width, height: 700)
		panel.layoutSubtreeIfNeeded()
		return panel
	}

	private func texts(in view: NSView) -> [String] {
		var out: [String] = []
		for sub in view.subviews {
			if let field = sub as? NSTextField, !field.isHidden { out.append(field.stringValue) }
			if let button = sub as? NSButton, !button.isHidden { out.append(button.title) }
			out += texts(in: sub)
		}
		return out
	}

	@Test func withNoAIThereIsACommandToRunRatherThanAFormToFillIn() async {
		let engine = engine()
		let panel = panel(engine)
		// Before anybody has looked, it does not claim there is nothing.
		#expect(!panel.setupForTesting.isHidden)
		#expect(texts(in: panel.setupForTesting) == ["Looking for an AI…"])

		await engine.refresh()
		#expect(engine.link == .missing)
		let said = texts(in: panel.setupForTesting)
		#expect(said.contains("No AI connected"))
		#expect(said.contains("sh /somewhere/ai-setup.sh"))
		#expect(said.contains("Copy Command"))
		#expect(said.contains("Check Again"))

		// And nothing can be sent into the void meanwhile.
		panel.inputForTesting.string = "hello"
		panel.sendForTesting()
		#expect(engine.conversation.entries.isEmpty)
		#expect(panel.inputForTesting.string == "hello")
	}

	@Test func theConversationIsShownAsItWasLeft() {
		var kept = Conversation()
		kept.entries = [ChatEntry(role: .user, text: "make the intro longer")]
		var answer = ChatEntry(role: .assistant, text: "The intro now ends at **00:03.500**.")
		answer.tools = [
			ChatEntry.Tool(name: "read_document", arguments: "{}", summary: "Read mia-take-1", state: .done),
			ChatEntry.Tool(name: "save_all", arguments: "{}", summary: "Declined: Save?", state: .declined),
		]
		kept.entries.append(answer)
		var failed = ChatEntry(role: .assistant, text: "", status: .failed)
		failed.problem = "The AI is not answering — nothing is listening at its address."
		kept.entries.append(failed)

		let panel = panel(engine(kept))
		let rows = panel.rowsForTesting
		#expect(rows.count == 3)
		#expect(rows[0].textForTesting == "make the intro longer")
		// Markdown read, not shown as typed.
		#expect(rows[1].textForTesting == "The intro now ends at 00:03.500.")
		#expect(rows[1].toolLinesForTesting == ["✓  Read mia-take-1", "–  Declined: Save?"])
		#expect(texts(in: rows[2]).contains("The AI is not answering — nothing is listening at its address."))
	}

	@Test func markdownIsReadAndHalfAnAnswerStillRenders() {
		let whole = ChatMarkdown.render("# Done\n\n- moved `music/bed.wav` **later**\n1. saved\n\n```yaml\nfrom: 00:03.500\n```")
		#expect(whole.string == "Done\n\n•\tmoved music/bed.wav later\n1.\tsaved\n\nfrom: 00:03.500")
		// Unclosed, as it is while it is being written.
		#expect(ChatMarkdown.render("**half").string == "**half")
		#expect(ChatMarkdown.render("```yaml\nfrom: 1").string == "from: 1")
	}

	// MARK: - In the window

	private func place() -> (DocumentPlace, MainWindowController) {
		let controller = MainWindowController(document: TakeDocument())
		let place = DocumentPlace.forTesting(controller)
		let engine = engine()
		place.makeChat = { ChatPanel(engine: engine, setupCommand: { "sh x" }, live: false) }
		return (place, controller)
	}

	@Test func theColumnOpensBesideTheDocumentAndGivesTheRoomBack() {
		let (place, controller) = place()
		let window = place.window
		let before = controller.contentRoot.frame.width
		#expect(!place.assistantShown)
		#expect(window.minSize.width == controller.minimumSize.width)

		place.setAssistantShown(true, remember: false, focus: false)
		window.layoutIfNeeded()
		#expect(place.assistantShown)
		// The document is never squeezed below what it needs, whatever the
		// screen had room for.
		#expect(window.minSize.width == controller.minimumSize.width + ChatPanel.width)
		#expect(controller.contentRoot.frame.width >= controller.minimumSize.width)
		#expect(abs(window.frame.width - controller.contentRoot.frame.width - ChatPanel.width) < 1)

		place.setAssistantShown(false, remember: false)
		window.layoutIfNeeded()
		#expect(!place.assistantShown)
		#expect(window.minSize.width == controller.minimumSize.width)
		#expect(abs(controller.contentRoot.frame.width - window.frame.width) < 1)
		#expect(controller.contentRoot.frame.width <= before + 1)
	}

	@Test func theBarKeepsItsButtonWhenTheDocumentChanges() {
		let (place, _) = place()
		func buttons() -> [NSButton] {
			var out: [NSButton] = []
			func walk(_ view: NSView) {
				if let button = view as? NSButton, button.accessibilityLabel() == "Assistant" { out.append(button) }
				view.subviews.forEach(walk)
			}
			walk(place.bar)
			return out
		}
		#expect(buttons().count == 1)
		// Another document furnishes the bar from nothing; the button is put back.
		place.adopt(MainWindowController(document: TakeDocument()))
		#expect(buttons().count == 1)
	}

	/// Typing in the column is not an edit to the take beside it.
	@Test func theComposerKeepsOutOfTheDocumentsUndo() {
		let composer = ComposerView()
		#expect(!composer.allowsUndo)
		#expect(composer.isEditable)
	}
}
