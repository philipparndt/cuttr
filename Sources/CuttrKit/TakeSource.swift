import Foundation

/// Where a take came from, when it did not come from a camera.
///
/// Most takes are a recording somebody made and there is nothing to say about
/// where they came from: the file is on the disk and the person who shot it is
/// holding the disk. A take fetched off the internet is the other case, and it
/// carries three obligations that a shot take does not — say which service
/// served it, say which item it was so somebody can go back and look, and carry
/// whatever mark the service's terms require to be shown. None of that can be
/// worked out later from the file itself.
///
/// It is written into the take rather than kept beside it, because a project
/// somebody can publish and one they cannot differ by exactly this block, and a
/// sidecar is the thing that gets left behind when the folder is copied.
public struct TakeSource: Sendable, Equatable {

	/// Which service. `giphy`, `tenor` — a slug, because it is matched against
	/// ``MemeProvider`` and typed by hand into files.
	public var provider: String

	/// What the service calls this item. Its own identifier, unchanged: it is
	/// the thing to hand back to the service to find this meme again.
	public var id: String

	/// The page a person can open to see it where it lives. Attribution that
	/// links is what most terms actually ask for, and a bare id does not link.
	public var page: String?

	/// What the service called it, before this program made a slug of it.
	public var title: String?

	/// The mark the service's terms require to be shown beside what it served —
	/// "Powered By GIPHY", and so on. Carried in the file because the file is
	/// what survives to the person doing the publishing, who is usually not the
	/// person who did the downloading.
	public var attribution: String?

	/// Keys inside this block that this version does not understand.
	///
	/// The same promise the take itself makes, one level down: a later version
	/// that records the licence, or the artist, must not have it deleted by an
	/// older build re-saving the file. Scalars only, which is all this block
	/// has ever held.
	public var extra: [String: String]

	public init(provider: String, id: String, page: String? = nil, title: String? = nil,
	            attribution: String? = nil, extra: [String: String] = [:]) {
		self.provider = provider
		self.id = id
		self.page = page
		self.title = title
		self.attribution = attribution
		self.extra = extra
	}

}
