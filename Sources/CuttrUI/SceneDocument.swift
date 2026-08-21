import AppKit
import CuttrCompose
import CuttrKit

/// One scene of a project, while somebody is editing it.
///
/// The project document still owns the file. This holds the scene as a value,
/// hands back a whole project when it changes, and keeps the undo stack — the
/// same arrangement ``TakeDocument`` has, and for the same reason: a scene is a
/// value, so the undo stack is a stack of values and there is no way to add an
/// operation that forgets to register one.
@MainActor
public final class SceneDocument {

	/// The project as this window last saw it. Replaced wholesale when the file
	/// changes underneath, because the file is what this program believes.
	public private(set) var project: Project
	public let baseURL: URL?
	public private(set) var name: String

	public let undoManager = UndoManager()

	/// Called after any change to the scene.
	public var onChange: (() -> Void)?
	/// The project, with this scene in it, for the document that owns the file.
	public var onWrite: ((Project) -> Void)?

	/// Where the playhead is, on the scene's own clock.
	public var playhead: Double = 0
	/// Which part is being worked on, and which of its keys.
	public var selectedPart: Int?
	public var selectedKey: Int?

	/// How long the scene runs while it is being edited.
	///
	/// The format has no such number and should not have one. A scene plays for
	/// as long as the overlay using it is on screen, which is the whole reason
	/// the same intro can run four seconds in one episode and six in the next —
	/// writing a length into the scene would make that a lie.
	///
	/// So it is a fact about the session rather than about the scene, held here
	/// and never written, exactly as ``TakeDocument`` holds which slugs somebody
	/// typed by hand. It starts as the longest this project actually plays the
	/// scene for, because that is the length somebody is editing against; when
	/// the project does not use the scene yet there is nothing to go on but the
	/// keys, so it is a second past the last of them.
	public var length: Double {
		didSet { length = max(0.2, length) }
	}

	/// Whether the scene differs from the one that came out of the project.
	public private(set) var isDirty = false

	/// True between the first event of a drag and the one that lets go.
	private var dragging = false

	public init(project: Project, baseURL: URL?, name: String, playedFor: Double? = nil) {
		self.project = project
		self.baseURL = baseURL
		self.name = name
		let scene = project.scenes[name] ?? Scene()
		// Never so short there is nothing to scrub: an overlay half a second
		// long is a real thing, but a stage half a second wide is not.
		self.length = max(0.5, playedFor ?? max(2, scene.lastKeyTime + 1))
	}

	public var scene: Scene { project.scenes[name] ?? Scene() }

	/// The words the project puts into this scene, for the stage to show.
	///
	/// Taken from the first overlay that uses it. A title card that says
	/// `{{title}}` while it is being made is a card nobody can judge the width
	/// of; showing it with the words the programme actually gives it is the
	/// difference between designing a layout and designing a placeholder.
	public var parameters: [String: String] {
		for overlay in project.overlays {
			if case .scene(let used, let given) = overlay.kind, used == name, !given.isEmpty {
				return given
			}
		}
		return [:]
	}

	/// The names this project defines, for the picker.
	public var sceneNames: [String] { project.scenes.keys.sorted() }

	// MARK: - Editing

	/// The one way the scene changes.
	public func apply(_ next: Scene, actionName: String) {
		guard next != scene else { return }
		let previous = scene
		undoManager.registerUndo(withTarget: self) { document in
			MainActor.assumeIsolated { document.apply(previous, actionName: actionName) }
		}
		undoManager.setActionName(actionName)
		project.scenes[name] = next
		isDirty = true
		onChange?()
		onWrite?(project)
	}

	/// The middle of a drag, and the end of it.
	///
	/// A part dragged across the frame is one decision and sixty changes: the
	/// first registers the undo, the rest are folded into it, and only the last
	/// one goes to the file. Undo then puts the part back where the drag
	/// started rather than where it was a frame ago, and the project is not
	/// rewritten sixty times on the way.
	public func drag(_ next: Scene, actionName: String, commit: Bool) {
		if !dragging {
			dragging = true
			let previous = scene
			undoManager.registerUndo(withTarget: self) { document in
				MainActor.assumeIsolated { document.apply(previous, actionName: actionName) }
			}
			undoManager.setActionName(actionName)
		}
		project.scenes[name] = next
		isDirty = true
		onChange?()
		if commit {
			dragging = false
			onWrite?(project)
		}
	}

	/// Sets one number on the key at the playhead, making a key there if there
	/// is not one already. The way every drag on the stage ends up in the file.
	public func set(
		_ field: Scene.Field, to value: Double, on part: Int,
		actionName: String, commit: Bool
	) {
		guard part < scene.parts.count else { return }
		var next = scene
		let (keys, index) = next.parts[part].inserting(keyAt: playhead)
		next.parts[part].keys = keys
		next.parts[part].keys[index][field] = value
		selectedKey = index
		drag(next, actionName: actionName, commit: commit)
	}

	/// Two numbers at once — a drag moves x and y together, and two undo steps
	/// for one drag is not an undo history.
	public func move(_ part: Int, x: Double, y: Double, commit: Bool) {
		guard part < scene.parts.count else { return }
		var next = scene
		let (keys, index) = next.parts[part].inserting(keyAt: playhead)
		next.parts[part].keys = keys
		next.parts[part].keys[index][.x] = x
		next.parts[part].keys[index][.y] = y
		selectedKey = index
		drag(next, actionName: "Move Part", commit: commit)
	}

	/// Names a shape kind at the playhead, which is what makes a morph.
	public func setShape(_ kind: Scene.ShapeKind, on part: Int) {
		guard part < scene.parts.count else { return }
		var next = scene
		let (keys, index) = next.parts[part].inserting(keyAt: playhead)
		next.parts[part].keys = keys
		next.parts[part].keys[index].shape = kind
		selectedKey = index
		apply(next, actionName: "Change Shape")
	}

	public func setKeyShape(_ kind: Scene.ShapeKind?, of index: Int, on part: Int) {
		guard part < scene.parts.count, index < scene.parts[part].keys.count else { return }
		var next = scene
		next.parts[part].keys[index].shape = kind
		apply(next, actionName: kind == nil ? "Inherit Shape" : "Change Shape")
	}

	public func setColor(_ color: RGBA?, on part: Int, commit: Bool = true) {
		guard part < scene.parts.count else { return }
		var next = scene
		let (keys, index) = next.parts[part].inserting(keyAt: playhead)
		next.parts[part].keys = keys
		next.parts[part].keys[index].color = color
		selectedKey = index
		drag(next, actionName: "Colour Part", commit: commit)
	}

	public func setContent(_ content: Scene.Part.Content, on part: Int, actionName: String) {
		guard part < scene.parts.count else { return }
		var next = scene
		next.parts[part].content = content
		apply(next, actionName: actionName)
	}

	/// A new part, in front of the others — which is where somebody looking at
	/// the stage expects the thing they just added to be.
	@discardableResult
	public func addPart(_ content: Scene.Part.Content) -> Int {
		var next = scene
		let key: Scene.Key
		switch content {
		case .background:
			key = Scene.Key(t: 0, opacity: 1)
		case .text:
			key = Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1, scale: 1, rotation: 0)
		case .shape:
			key = Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0.4, height: 0.01)
		case .image:
			key = Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0.2, height: 0.2)
		case .frames, .component:
			// The whole frame, because a component is nearly always the picture
			// — a chart, a table, a map — and a sequence dropped in at a fifth
			// of the frame is a sequence somebody then has to find.
			key = Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 1, height: 1)
		case .bar:
			// Empty at the start, because a bar that is added full has nothing
			// to show and the next thing anybody does is give it a second key.
			key = Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1,
			                width: 0.5, height: 0.012, progress: 0)
		case .spinner:
			key = Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1)
		case .roll:
			// Below the bottom of the frame, because that is where a roll starts
			// from — and see below for why it does not stay there.
			key = Scene.Key(t: 0, x: 0.5, y: -0.6, opacity: 1, scale: 1, ease: .linear)
		}
		var made = [key]
		// The one part that is useless with a single key: a roll standing still
		// off the bottom of the frame looks exactly like nothing at all. So it
		// arrives scrolling, and the second key is the one somebody drags.
		if case .roll = content {
			made.append(Scene.Key(t: 6, y: 1.6, ease: .linear))
		}
		next.parts.append(Scene.Part(content: content, keys: made))
		// A background goes underneath everything, whatever order it was added
		// in: it is the ground, and a ground over the top is a blank frame.
		if case .background = content, next.parts.count > 1 {
			let added = next.parts.removeLast()
			next.parts.insert(added, at: 0)
			apply(next, actionName: "Add Background")
			selectedPart = 0
			return 0
		}
		apply(next, actionName: "Add Part")
		selectedPart = next.parts.count - 1
		return next.parts.count - 1
	}

	public func removePart(_ index: Int) {
		guard index < scene.parts.count else { return }
		var next = scene
		next.parts.remove(at: index)
		apply(next, actionName: "Remove Part")
		selectedPart = next.parts.isEmpty ? nil : min(index, next.parts.count - 1)
		selectedKey = nil
	}

	/// Moves a part up or down the list, which is the order they are drawn in.
	public func movePart(_ index: Int, by offset: Int) {
		let target = index + offset
		guard index < scene.parts.count, target >= 0, target < scene.parts.count else { return }
		var next = scene
		let part = next.parts.remove(at: index)
		next.parts.insert(part, at: target)
		apply(next, actionName: "Reorder Parts")
		selectedPart = target
	}

	// MARK: - Keys

	@discardableResult
	public func addKey(at t: Double, on part: Int) -> Int? {
		guard part < scene.parts.count else { return nil }
		var next = scene
		let (keys, index) = next.parts[part].inserting(keyAt: t)
		next.parts[part].keys = keys
		apply(next, actionName: "Add Key")
		selectedKey = index
		return index
	}

	public func removeKey(_ index: Int, on part: Int) {
		guard part < scene.parts.count, scene.parts[part].keys.count > 1,
		      index < scene.parts[part].keys.count else { return }
		var next = scene
		next.parts[part].keys.remove(at: index)
		apply(next, actionName: "Remove Key")
		selectedKey = nil
	}

	public func setKeyTime(_ t: Double, of index: Int, on part: Int) {
		guard part < scene.parts.count, index < scene.parts[part].keys.count else { return }
		var next = scene
		next.parts[part].keys[index].t = max(0, t)
		next.parts[part].keys.sort { $0.t < $1.t }
		apply(next, actionName: "Move Key")
	}

	public func setEase(_ ease: Scene.Ease, of index: Int, on part: Int) {
		guard part < scene.parts.count, index < scene.parts[part].keys.count else { return }
		var next = scene
		next.parts[part].keys[index].ease = ease
		apply(next, actionName: "Change Easing")
	}

	/// Sets or clears a field on a key that already exists — the key table's
	/// job, where the stage's is to write at the playhead.
	public func setField(
		_ field: Scene.Field, to value: Double?, of index: Int, on part: Int
	) {
		guard part < scene.parts.count, index < scene.parts[part].keys.count else { return }
		var next = scene
		next.parts[part].keys[index][field] = value
		apply(next, actionName: value == nil ? "Inherit \(field.rawValue)" : "Set \(field.rawValue)")
	}

	// MARK: - The file underneath

	/// The project changed elsewhere — reloaded from disk, or edited in the
	/// project window. Adopted unless a drag is in progress, because taking the
	/// scene out from under a drag is worse than being a moment out of date.
	public func refresh(_ project: Project) {
		guard !dragging else { return }
		self.project = project
		isDirty = false
		onChange?()
	}

	/// Switches to another scene of the same project.
	public func show(_ name: String) {
		guard project.scenes[name] != nil, name != self.name else { return }
		self.name = name
		selectedPart = nil
		selectedKey = nil
		playhead = 0
		length = max(2, scene.lastKeyTime + 1)
		undoManager.removeAllActions()
		onChange?()
	}

	/// A scene with nothing in it but a ground and a title, under a name of its
	/// own. What File ▸ New Scene makes.
	///
	/// Not an empty one: an editor that opens on nothing gives somebody a blank
	/// stage and no idea which of the four buttons starts a title card. Two
	/// parts is enough to show what a scene is made of and enough to delete.
	public func add(sceneNamed requested: String) -> String {
		let slug = Slug.unique(Slug.make(from: requested), taken: Set(project.scenes.keys))
		var project = self.project
		project.scenes[slug] = SceneDocument.starter
		self.project = project
		name = slug
		selectedPart = nil
		selectedKey = nil
		playhead = 0
		length = 4
		undoManager.removeAllActions()
		onChange?()
		onWrite?(project)
		return slug
	}

	public static let starter = Scene(parts: [
		.init(content: .background(Scene.Background(
			from: RGBA(hex: "#0b1220")!, to: RGBA(hex: "#1d3557")!, angle: 90)),
			keys: [.init(t: 0, opacity: 0), .init(t: 0.4, opacity: 1, ease: .out)]),
		.init(content: .text("{{title}}", style: "title", tracking: 0.08), keys: [
			.init(t: 0.3, x: 0.5, y: 0.46, opacity: 0, scale: 0.94),
			.init(t: 1.1, y: 0.5, opacity: 1, scale: 1, ease: .out),
		]),
	])
}
