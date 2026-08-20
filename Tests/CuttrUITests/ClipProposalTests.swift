import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// A proposed name is a proposal.
///
/// Three things are not negotiable about a name that came from a model, and
/// two of them live here: it arrives editable and ready to be typed over, and
/// it never puts itself in front of what somebody has begun to type. The third
/// — that it never repoints a slug somebody chose — is
/// ``ClipProposalSlugTests`` below.
@MainActor @Suite struct ClipProposalTests {

	private func timeline() -> (TimelineView, TakeDocument, Clip) {
		let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
		let clip = Clip(slug: "clip-1", start: 1, end: 5)
		let document = TakeDocument(take: Take(video: "a.mov", clips: [clip]))
		view.document = document
		view.setZoom(0.01)
		return (view, document, clip)
	}

	/// The field opens with the proposal in it, not the clip's own name, and
	/// with the proposal selected — one keystroke to keep, one to type over.
	@Test func aProposalArrivesInTheFieldReadyToBeTypedOver() {
		let (view, document, clip) = timeline()
		_ = document
		view.beginRenaming(clip, proposing: "Am liebsten tut sie")
		#expect(view.renamingText == "Am liebsten tut sie")
		// And nothing has been written: a proposal that committed itself would
		// be a rename nobody asked for.
		#expect(view.document?.take.clips[0].name == "")
		#expect(view.document?.take.clips[0].slug == "clip-1")
		view.endRenaming(commit: false)
	}

	/// Without one it is still the clip's own name, which is what `N` does.
	@Test func renamingWithoutAProposalIsUnchanged() {
		let (view, document, _) = timeline()
		_ = document
		var named = Clip(slug: "intro", name: "Intro", start: 1, end: 5)
		named.name = "Intro"
		view.beginRenaming(named)
		#expect(view.renamingText == "Intro")
		view.endRenaming(commit: false)
	}

	/// The model answers about seven tenths of a second after the field opened.
	/// If nobody has touched it, a better name replaces the first words.
	@Test func aBetterNameArrivingLaterReplacesAnUntouchedField() {
		let (view, document, clip) = timeline()
		_ = document
		view.beginRenaming(clip, proposing: "Am liebsten tut sie")
		#expect(view.repropose("Fahrradfahren", for: clip.id, replacing: "Am liebsten tut sie"))
		#expect(view.renamingText == "Fahrradfahren")
		view.endRenaming(commit: false)
	}

	/// And if somebody has started typing, it does not. This is the whole of
	/// the guard: a field that changed under their fingers would be exactly
	/// what a proposal must never be.
	@Test func aBetterNameDoesNotOverwriteWhatSomebodyIsTyping() {
		let (view, document, clip) = timeline()
		_ = document
		view.beginRenaming(clip, proposing: "Am liebsten tut sie")
		view.setRenamingTextForTest("Omas Fahrrad")
		#expect(!view.repropose("Fahrradfahren", for: clip.id, replacing: "Am liebsten tut sie"))
		#expect(view.renamingText == "Omas Fahrrad")
		view.endRenaming(commit: false)
	}

	/// Nor a field that is open on a different clip, nor one that is not open
	/// at all — an answer for a clip somebody has moved on from is an answer
	/// nobody wants.
	@Test func aBetterNameForSomethingElseIsIgnored() {
		let (view, document, clip) = timeline()
		_ = document
		#expect(!view.repropose("Fahrradfahren", for: clip.id, replacing: "Am liebsten tut sie"))
		view.beginRenaming(clip, proposing: "Am liebsten tut sie")
		#expect(!view.repropose("Fahrradfahren", for: UUID(), replacing: "Am liebsten tut sie"))
		#expect(view.renamingText == "Am liebsten tut sie")
		view.endRenaming(commit: false)
	}

	/// Committing goes the way a name typed by hand goes, which is the point:
	/// there is one route into a take for a name and a model does not get its
	/// own.
	@Test func keepingAProposalNamesTheClipAndDerivesItsSlug() {
		let (view, document, clip) = timeline()
		// The wire the window makes: committing an in-place rename is
		// `setName`, which is where the slug rule lives.
		view.onRenameInPlace = { id, name in document.setName(name, for: id) }
		view.beginRenaming(clip, proposing: "Fahrradfahren")
		view.endRenaming(commit: true)
		#expect(document.take.clips[0].name == "Fahrradfahren")
		#expect(document.take.clips[0].slug == "fahrradfahren")
	}
}

/// A proposal never silently repoints a slug.
///
/// A slug is what the project assembly file points at. Once somebody has typed
/// one, renaming the clip — by hand or from a model, which is the same route —
/// must not change what that file finds.
@MainActor @Suite struct ClipProposalSlugTests {

	@Test func aSlugSomebodyTypedSurvivesAProposedName() {
		let clip = Clip(slug: "clip-1", start: 1, end: 5)
		let document = TakeDocument(take: Take(video: "a.mov", clips: [clip]))
		document.setSlug("die-fahrradtour", for: clip.id)
		document.setName("Fahrradfahren", for: clip.id, actionName: "Name from Words")
		#expect(document.take.clips[0].name == "Fahrradfahren")
		#expect(document.take.clips[0].slug == "die-fahrradtour")
	}

	/// And one nobody has claimed follows the name, the way it always has.
	@Test func aSlugNobodyClaimedFollowsTheProposedName() {
		let clip = Clip(slug: "clip-1", start: 1, end: 5)
		let document = TakeDocument(take: Take(video: "a.mov", clips: [clip]))
		document.setName("Fahrradfahren", for: clip.id, actionName: "Name from Words")
		#expect(document.take.clips[0].slug == "fahrradfahren")
	}
}
