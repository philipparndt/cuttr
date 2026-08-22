import CuttrKit
import Foundation

/// The files a resolve reads, kept between resolves.
///
/// **Why this exists.** Resolving is not a background job: `ComposeDocument` is
/// on the main actor and calls it synchronously on every change to the project,
/// from sixty-odd places. That is the right shape — everything on screen reads
/// `resolved`, and a window that draws one state while holding another is worse
/// than a slow one — but it means every resolve happens on the thread the
/// person is typing on.
///
/// And every resolve re-read the disk. Every take file, parsed again through
/// YAML; and for every anchor in every take, its solved path sidecar, which is
/// a line per tracked frame — twenty-five a second for as long as the shot
/// runs. None of it had changed. Dragging an overlay along the programme is
/// dozens of changes a second, so it was dozens of times a second, on the main
/// thread, and the project only had to get big enough for that to be felt.
///
/// So: read through this instead. A `stat` on each file, and the parse is
/// skipped when the file is the one already parsed. `stat` is what remains of
/// the per-change cost, and it is the cheapest question the file system
/// answers.
///
/// **Why modification date *and* size.** A date on its own has a resolution,
/// and two writes inside it — which an editor saving twice quickly does, and
/// which this program's own atomic replace can do — would look like no write at
/// all. Size catches the ones where the content actually changed. A file
/// rewritten to the same length in the same second is the one case this misses,
/// and it is the case where re-reading would have made no difference.
final class ResolvedFiles: @unchecked Sendable {

	/// Shared, because the point is to survive from one resolve to the next.
	/// Behind a lock because a render resolves off the main thread while a
	/// window resolves on it.
	static let shared = ResolvedFiles()

	private let lock = NSLock()
	private var takes: [String: Stamped<Take>] = [:]
	private var paths: [String: Stamped<AnchorPath>] = [:]

	private struct Stamped<Value> {
		var modified: Date
		var size: Int
		var value: Value
	}

	/// What the file system says about a file, or nothing when it is not there.
	///
	/// `FileManager` and deliberately not `URL.resourceValues(forKeys:)`. A
	/// `URL` *caches* the values it has been asked for, so a URL that has been
	/// stamped once goes on reporting that stamp however many times the file is
	/// rewritten underneath it — and the cache above would then serve the first
	/// version of a take for the rest of the session. That is the way this
	/// whole idea goes wrong, and it went wrong exactly that way the first
	/// time: `aTakeThatChangedIsReadAgain` and
	/// `anAnchorPathThatChangedIsReadAgain` both failed, and they are here
	/// because of it.
	private func stamp(_ url: URL) -> (modified: Date, size: Int)? {
		guard let values = try? FileManager.default
			.attributesOfItem(atPath: url.standardizedFileURL.path),
			let modified = values[.modificationDate] as? Date,
			let size = values[.size] as? Int
		else { return nil }
		return (modified, size)
	}

	// MARK: - Reading

	/// A take, parsed once per version of the file.
	///
	/// Throws what reading or parsing threw, exactly as the caller's own
	/// `String(contentsOf:)` and `TakeReader.read` did — a file that has gone is
	/// still an error and still says so.
	func take(at url: URL) throws -> Take {
		let key = url.standardizedFileURL.path
		let now = stamp(url)
		if let now {
			lock.lock()
			let held = takes[key]
			lock.unlock()
			if let held, held.modified == now.modified, held.size == now.size {
				return held.value
			}
		}
		counted(key)
		let take = try TakeReader.read(try String(contentsOf: url, encoding: .utf8))
		if let now {
			lock.lock()
			takes[key] = Stamped(modified: now.modified, size: now.size, value: take)
			lock.unlock()
		}
		return take
	}

	/// A solved anchor path, parsed once per version of the file. `nil` for one
	/// that is not there or cannot be read, which is what the resolver already
	/// treats as "this anchor has no path".
	func anchorPath(at url: URL) -> AnchorPath? {
		let key = url.standardizedFileURL.path
		let now = stamp(url)
		if let now {
			lock.lock()
			let held = paths[key]
			lock.unlock()
			if let held, held.modified == now.modified, held.size == now.size {
				return held.value
			}
		}
		counted(key)
		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
		let solved = AnchorPath.read(text)
		if let now {
			lock.lock()
			paths[key] = Stamped(modified: now.modified, size: now.size, value: solved)
			lock.unlock()
		}
		return solved
	}

	// MARK: - For the tests

	/// How many times a file has actually been read and parsed, by path. The
	/// only thing worth asserting about a cache is that it did not do the work
	/// twice, and that cannot be seen from outside without this.
	private var counts: [String: Int] = [:]

	/// How many times each file was actually read and parsed.
	func reads(of url: URL) -> Int {
		lock.lock()
		defer { lock.unlock() }
		return counts[url.standardizedFileURL.path] ?? 0
	}

	func forget() {
		lock.lock()
		takes = [:]
		paths = [:]
		counts = [:]
		lock.unlock()
	}

	private func counted(_ key: String) {
		lock.lock()
		counts[key, default: 0] += 1
		lock.unlock()
	}
}
