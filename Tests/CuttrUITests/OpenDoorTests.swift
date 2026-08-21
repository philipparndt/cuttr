import AppKit
import Foundation
import Testing
@testable import CuttrUI

/// Which opener a document goes to.
///
/// The palette's Recent Documents rows did nothing. There are three openers,
/// and the rule for choosing between them had been written out separately at
/// each place that needed one — so the palette sent a project to the take
/// opener, which treats anything that is not a `.cuttr` as footage to make a
/// take out of. It looked in the project for a video, found none, and returned
/// without a word. And every row in that list is a project, because that is
/// what the recents list deliberately holds.
@MainActor @Suite struct OpenDoorTests {

	private func url(_ name: String) -> URL {
		URL(fileURLWithPath: "/Volumes/500G/dingsda/\(name)")
	}

	@Test func aProjectGoesToTheProjectOpener() {
		#expect(AppDelegate.Door.of(url("dingsda.cuttrproj")) == .project)
	}

	@Test func aTakeGoesToTheTakeOpener() {
		#expect(AppDelegate.Door.of(url("takes/Leni.cuttr")) == .take)
	}

	/// Anything else is footage, which is what makes a take out of a recording
	/// that has no cut list yet.
	@Test func anythingElseIsFootage() {
		for name in ["MVI_5590.MP4", "IMG_1803.mov", "tone.wav", "notes.txt", "noextension"] {
			#expect(AppDelegate.Door.of(url(name)) == .media)
		}
	}

	/// Case is not a decision anybody made about their file names.
	@Test func theExtensionIsReadWhateverCaseItIsIn() {
		#expect(AppDelegate.Door.of(url("A.CUTTRPROJ")) == .project)
		#expect(AppDelegate.Door.of(url("A.Cuttr")) == .take)
	}

	/// The one that was wrong: a project must not read as a take, because the
	/// take opener is where a project went to be silently dropped.
	@Test func aProjectIsNeverATake() {
		#expect(AppDelegate.Door.of(url("dingsda.cuttrproj")) != .take)
		#expect(AppDelegate.Door.of(url("dingsda.cuttrproj")) != .media)
	}
}
