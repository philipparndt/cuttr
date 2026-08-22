import Foundation

/// How a file this program writes refers to another file on the disk.
///
/// **Relative wherever it can be.** A project, its takes and its media are one
/// folder that gets copied to another disk, handed to somebody else, or put in
/// a repository and shared — and a file full of `/Users/somebody/…` survives
/// none of those. The absolute path that started this was
/// `/Users/mia/Desktop/dingsda/dingsda-cuttr/media/…` in a project that now
/// lives on `/Volumes/500G`: not merely untidy, but pointing at a file that is
/// not there any more on the only machine that ever had it.
///
/// **One implementation.** There were four of these, character for character
/// the same but for how many `..` each would tolerate, and the one that mattered
/// — a sound chosen through the file panel — was a fifth written inline that
/// only handled the file being *under* the project. Everything that writes a
/// path comes here now.
public enum MediaPath {

	/// How far up a relative path may climb before an absolute one is better.
	///
	/// Two `..` is `../../music/x.wav`, which is still recognisably one folder
	/// somebody would copy around. Past that it is two unrelated places on a
	/// disk, and an absolute path at least says where the file actually is
	/// rather than describing a route that will not survive the move.
	public static let ordinaryUps = 2

	/// `target`, written relative to `folder`, or absolute when it cannot
	/// reasonably be.
	///
	/// **`standardized` and deliberately not `standardizedFileURL`.** That is
	/// the one that consults the file system, and it produced an absolute path
	/// here on the first real meme download: the media had just been written
	/// and the take file had not, so the same folder standardized to `/tmp/…`
	/// for the one that existed and stayed `/private/tmp/…` for the one that
	/// did not — two paths with nothing in common and no relative path between
	/// them. Comparing them as text is both correct and the only thing that
	/// *can* be correct, since one of the two files is often about to be
	/// created.
	public static func relative(_ target: URL, toFolder folder: URL,
	                            ups allowed: Int = ordinaryUps) -> String {
		let base = folder.standardized.pathComponents
		let parts = target.standardized.pathComponents
		var shared = 0
		while shared < base.count, shared < parts.count, base[shared] == parts[shared] {
			shared += 1
		}
		let ups = base.count - shared
		guard ups <= allowed else { return target.path }
		return (Array(repeating: "..", count: ups) + parts[shared...]).joined(separator: "/")
	}

	/// The same, for a file that sits beside the one being written — a take's
	/// video against the take, a sound against the project.
	public static func relative(_ target: URL, beside file: URL,
	                            ups allowed: Int = ordinaryUps) -> String {
		relative(target, toFolder: file.deletingLastPathComponent(), ups: allowed)
	}

	/// Whatever somebody typed, dragged or pasted into a path field, made
	/// relative when it turns out to name a file inside the project.
	///
	/// **Why a field needs this at all.** Dragging a file onto an `NSTextField`
	/// puts its absolute path in, and so does pasting one out of the Finder.
	/// The file panel beside the field has always written a relative path, so
	/// two doors into the same field wrote two different things and only one of
	/// them travelled. This is that second door.
	///
	/// Only an absolute path is touched. Something already relative is what
	/// somebody meant, and re-deriving it against a folder would be this
	/// function inventing a path nobody asked for.
	public static func tidy(_ written: String, against folder: URL?) -> String {
		let text = written.trimmingCharacters(in: .whitespaces)
		guard let folder, text.hasPrefix("/") else { return text }
		return relative(URL(fileURLWithPath: text), toFolder: folder)
	}
}
