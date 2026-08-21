import CuttrCompose
import CuttrKit
import Foundation

// The renderer without a window.
//
// Rendering is minutes of encoding and the machine doing it does not need a
// screen — this is what a build machine, a `make` rule or an overnight run
// reaches for. It reads exactly the same project file the composing window
// writes, and produces exactly the same frames, because both go through
// `Renderer.build`.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
	FileHandle.standardError.write("""
	usage: cuttr-render <project.cuttrproj> [-o output.mov] [--solve] [--quiet]
	       cuttr-render --faces <video.mov> [--at seconds]

	  -o        where to write; defaults to the project's own `output.file`
	  --solve   re-solve every anchor's path before rendering, rather than
	            using the sidecars the composing window wrote
	  --describe
	            print what the project resolves to — every clip and card with its
	            times, every sound with its level, every overlay with when it is
	            on, what it says then and whether its anchor was found — and
	            render nothing. The first question
	            when something is missing from a render is whether it was ever
	            in the programme.
	  --quiet   no progress

	  --analyse measure every take's loudness and colour, and write the numbers
	            back into the take files. Do this once per recording; every
	            project that uses it then levels and matches for free.

	  --silence <take.cuttr> [--clips] [--from t --to t] [--handle t]
	            where the quiet is in that take, measured off the audio rather
	            than guessed from the word times. Three questions:
	            on its own, every stretch of quiet and how long it is, with the
	            words on either side of it;
	            --clips, how each existing clip's marks sit against the speech —
	            whether it has air or is cutting through a word;
	            --from/--to, what that span would become once its marks are put
	            on the sound and given handles. Times may be seconds or
	            timecode. --handle 0 for a hard cut. See docs/silence.md.

	  --speaking <take.cuttr> --from s --to s
	            who, of the take's tracked people, is talking over that span.
	            An anchor is a person: rename one to `mia` and clips she speaks
	            in are named after her.

	  --speakers <take.cuttr> [--truth labels] [--method m] [--voices n]
	            [--taught n] [--trials t] [--blind]
	            work out who is speaking in each line of that take's transcript,
	            and print it. With --truth, score it against a file of hand-made
	            labels — a time and a name per line, see Tests/Fixtures — and
	            print the accuracy, which is the only honest way to decide
	            whether a method is worth offering at all. Where the sidecar
	            already names speakers, those are the labels and --truth is not
	            needed.
	            --taught n hands the pass only n answered lines per speaker and
	            scores it on the rest, which is the workflow the pane has:
	            answer two lines, ask, check the other sixty-six. --trials t
	            repeats that with t different draws and averages, because which
	            two lines somebody happened to answer moves the figure by twenty
	            points and one draw is not a measurement.
	            --blind makes it cluster instead of being taught by the names
	            already there, which is what it used to do and is the column the
	            table in docs/speakers.md is read against.
	            Methods: timbre (the default; no model, nothing fetched),
	            voice-analytics, embedding, mouth. See docs/speakers.md for what
	            each one scored on the takes this was built against.

	  --faces   what Vision can see in one frame, and where. Answers "is there
	            a face here for an anchor to lock on to?" before spending a
	            minute finding out, and prints the coordinates an anchor's
	            `point:` wants.

	""".data(using: .utf8)!)
	exit(2)
}

var projectPath: String?
var outputPath: String?
var solve = false
var describe = false
var quiet = false
var facesOf: String?
var facesAt = 0.0
var analyse = false
var speakingIn: String?
var speakersIn: String?
var truthPath: String?
var method = SpeakerProposal.Method.timbre
var voices = 2
var taught = 0
var trials = 1
var blind = false
var mouthSamples = SpeakerProposal.mouthSamples
var spanFrom = 0.0
var spanTo = 0.0
var spanAsked = false
var silenceIn: String?
var showClips = false
var handle = SpeechMap.handle
var index = 0
while index < arguments.count {
	switch arguments[index] {
	case "-o", "--output":
		index += 1
		guard index < arguments.count else { usage() }
		outputPath = arguments[index]
	case "--describe":
		describe = true
	case "--faces":
		index += 1
		guard index < arguments.count else { usage() }
		facesOf = arguments[index]
	case "--speakers":
		index += 1
		guard index < arguments.count else { usage() }
		speakersIn = arguments[index]
	case "--mouth-samples":
		index += 1
		guard index < arguments.count, let value = Int(arguments[index]) else { usage() }
		mouthSamples = value
	case "--truth":
		index += 1
		guard index < arguments.count else { usage() }
		truthPath = arguments[index]
	case "--method":
		index += 1
		guard index < arguments.count,
		      let chosen = SpeakerProposal.Method(rawValue: arguments[index]) else { usage() }
		method = chosen
	case "--voices":
		index += 1
		guard index < arguments.count, let value = Int(arguments[index]), value >= 2 else { usage() }
		voices = value
	case "--blind":
		blind = true
	case "--taught":
		index += 1
		guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else { usage() }
		taught = value
	case "--trials":
		index += 1
		guard index < arguments.count, let value = Int(arguments[index]), value >= 1 else { usage() }
		trials = value
	case "--speaking":
		index += 1
		guard index < arguments.count else { usage() }
		speakingIn = arguments[index]
	case "--silence":
		index += 1
		guard index < arguments.count else { usage() }
		silenceIn = arguments[index]
	case "--clips":
		showClips = true
	case "--handle":
		index += 1
		guard index < arguments.count,
		      let value = Timecode.parse(arguments[index]), value >= 0 else { usage() }
		handle = value
	// Timecode as well as bare seconds, so a span can be copied straight out of
	// a take file: that is where somebody reading one gets their numbers.
	case "--from":
		index += 1
		guard index < arguments.count, let value = Timecode.parse(arguments[index]) else { usage() }
		spanFrom = value
		spanAsked = true
	case "--to":
		index += 1
		guard index < arguments.count, let value = Timecode.parse(arguments[index]) else { usage() }
		spanTo = value
		spanAsked = true
	case "--at":
		index += 1
		guard index < arguments.count, let value = Double(arguments[index]) else { usage() }
		facesAt = value
	case "--analyse", "--analyze": analyse = true
	case "--solve": solve = true
	case "--quiet": quiet = true
	case "-h", "--help": usage()
	default:
		guard projectPath == nil else { usage() }
		projectPath = arguments[index]
	}
	index += 1
}
func fail(_ message: String) -> Never {
	FileHandle.standardError.write("cuttr-render: \(message)\n".data(using: .utf8)!)
	exit(1)
}

/// A shuffle with the seed written down.
///
/// For `--taught`: which lines somebody happened to answer moves the accuracy
/// by twenty points, so one draw is an anecdote and the average of twenty-five
/// is a measurement. Seeded rather than random, because a figure quoted in
/// `docs/speakers.md` has to come back the same tomorrow.
struct Dice {
	var state: UInt64

	mutating func next() -> UInt64 {
		state = state &+ 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}

	mutating func shuffled<T>(_ items: [T]) -> [T] {
		var out = items
		guard out.count > 1 else { return out }
		for index in (1 ..< out.count).reversed() {
			out.swapAt(index, Int(next() % UInt64(index + 1)))
		}
		return out
	}
}

if let speakersIn {
	let takeURL = URL(fileURLWithPath: speakersIn).standardizedFileURL
	let directory = takeURL.deletingLastPathComponent()
	do {
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		guard let wordsPath = take.words?.path else { fail("that take has no words to label") }
		let sidecar = URL(fileURLWithPath: wordsPath, relativeTo: directory).standardizedFileURL
		let said = Transcript.read(try String(contentsOf: sidecar, encoding: .utf8))
		guard !said.isEmpty else { fail("that take's sidecar is empty") }

		// The recorder when there is one, on its own clock, with the take's
		// offset relating it to the video's — the same choice `Transcriber`
		// makes, for the same reason: it is the better microphone.
		let listenTo: URL
		let offset: Double
		if let audio = take.audio {
			listenTo = URL(fileURLWithPath: audio.file, relativeTo: directory).standardizedFileURL
			offset = take.video == nil ? 0 : audio.offset
		} else if let video = take.video {
			listenTo = URL(fileURLWithPath: video, relativeTo: directory).standardizedFileURL
			offset = 0
		} else {
			fail("that take has nothing to listen to")
		}

		// The people this take already follows, for the method that looks at
		// the picture rather than listening to it.
		var faces: [SpeakerDetector.Candidate] = []
		if method.watchesThePicture {
			faces = take.anchors.compactMap { anchor in
				guard let sidecar = anchor.path,
				      let text = try? String(
					      contentsOf: URL(fileURLWithPath: sidecar, relativeTo: directory),
					      encoding: .utf8)
				else { return nil }
				return SpeakerDetector.Candidate(name: anchor.name, path: AnchorPath.read(text))
			}
			guard !faces.isEmpty else { fail("that take has no solved anchors to watch") }
		}
		let videoURL = take.video.map {
			URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL
		}

		let lines = said.lines

		// Where the labels come from. A file when one is named; otherwise the
		// sidecar's own `# speaker:` markers, which is what somebody labelling
		// a take by hand in the app has already produced. Either way a label is
		// a time and a name and never a word — see `SpeakerLabels`.
		var truth = SpeakerLabels()
		if let truthPath {
			truth = SpeakerLabels.read(
				try String(contentsOf: URL(fileURLWithPath: truthPath), encoding: .utf8))
			guard !truth.isEmpty else { fail("no labels in \(truthPath)") }
		} else {
			truth = SpeakerLabels(labels: lines.compactMap { line in
				guard let span = said.span(line), let who = said.speaker(ofLine: line)
				else { return nil }
				return SpeakerLabels.Label(at: span.start, who: who)
			})
		}

		/// One measurement: hand the pass `asked` and score what comes back
		/// against the lines it was not told about.
		func measure(_ asked: Transcript, withheld: SpeakerLabels) async throws
			-> (offer: SpeakerProposal.Offer, score: SpeakerLabels.Score?, took: Double) {
			let clock = Date()
			let offer = try await SpeakerProposal.propose(
				for: asked, audio: listenTo, offset: offset, method: method, voices: voices,
				locale: take.words?.locale ?? "", video: videoURL, faces: faces,
				samples: mouthSamples, blind: blind)
			let took = Date().timeIntervalSince(clock)
			guard !withheld.isEmpty else { return (offer, nil, took) }
			return (offer, withheld.score(offer.byLine, against: asked), took)
		}

		if taught > 0 {
			guard !truth.isEmpty else { fail("nothing to teach it — this take has no labels") }
			// Which lines are given away, and a different draw each trial. The
			// dice are seeded, so the same command prints the same number.
			var dice = Dice(state: 0x5EED)
			var totals = (agreement: 0.0, placed: 0.0, withheld: 0.0, separation: 0.0, runs: 0.0)
			for trial in 0 ..< trials {
				var pool: [String: [Int]] = [:]
				for (index, line) in lines.enumerated() {
					guard let who = said.speaker(ofLine: line) else { continue }
					pool[who, default: []].append(index)
				}
				var given = Set<Int>()
				for who in pool.keys.sorted() {
					// The first n in time order for the first trial, so one run
					// of this command is reproducible without a seed in it.
					let order = trial == 0 ? pool[who]! : dice.shuffled(pool[who]!)
					given.formUnion(order.prefix(taught))
				}
				var asked = said
				var withheld: [SpeakerLabels.Label] = []
				for (index, line) in lines.enumerated() where !given.contains(index) {
					if let span = said.span(line), let who = truth.who(at: span.start) {
						withheld.append(SpeakerLabels.Label(at: span.start, who: who))
					}
					asked.assign(nil, to: line)
				}
				let (offer, score, _) = try await measure(
					asked, withheld: SpeakerLabels(labels: withheld))
				guard let score, score.labelled > 0 else { continue }
				totals.agreement += score.agreement
				totals.placed += Double(score.placed)
				totals.withheld += Double(score.labelled)
				totals.separation += offer.separation
				totals.runs += 1
			}
			guard totals.runs > 0 else { fail("no trial had anything to score") }
			print("\(method.rawValue), taught \(taught) line(s) per speaker,"
				+ " \(Int(totals.runs)) draw(s) of \(lines.count) lines")
			print(String(
				format: "agreement %.1f%% of the %.0f lines withheld, %.0f offered, separation %.3f",
				totals.agreement / totals.runs * 100, totals.withheld / totals.runs,
				totals.placed / totals.runs, totals.separation / totals.runs))
			print(String(format: "always answering the commonest: %.1f%%", truth.commonest * 100))
			exit(0)
		}

		let (offer, score, took) = try await measure(said, withheld: truth)
		print("\(method.rawValue): \(lines.count) lines, \(offer.byLine.count) placed,"
			+ " \(offer.skipped) too short or too quiet,"
			+ (offer.taught ? " taught by the names already there," : " clustered blind,")
			+ String(format: " separation %.3f, %.1fs", offer.separation, took))

		guard let score else {
			for line in lines {
				let who = offer.byLine[line.lowerBound] ?? "\u{2014}"
				print(who.padding(toLength: 12, withPad: " ", startingAt: 0)
					+ " " + said.phrase(line, limit: 9))
			}
			exit(0)
		}
		guard score.labelled > 0 else {
			fail("none of the \(truth.count) labels line up with this take's lines —"
				+ " are they the same recording?")
		}
		print(String(format: "accuracy %.1f%% of the %d lines labelled, %.1f%% of the %d it placed",
		             score.accuracy * 100, score.labelled,
		             score.accuracyWherePlaced * 100, score.placed))
		print(String(format: "agreement under the names it chose: %.1f%%", score.agreement * 100))
		print(String(format: "always answering the commonest: %.1f%%", truth.commonest * 100))
		print("wrong lines:")
		for line in score.wrong {
			print(String(format: "  %@  said %@ truth %@", Timecode.string(line.at),
			             (line.said ?? "\u{2014}").padding(toLength: 12, withPad: " ", startingAt: 0),
			             line.truth))
		}
	} catch {
		fail(error.localizedDescription)
	}
	exit(0)
}

// Where the quiet is.
//
// Computed on the spot, every time, and deliberately not written anywhere. A
// sidecar would be a fourth file to keep in step with the media — the take
// already has a transcript and a path per anchor — and the thing that earns a
// sidecar is being expensive: recognising five minutes of German is a minute of
// somebody's afternoon. This is a decode and 50 ms of arithmetic. A file that
// can go stale is a worse answer than one that cannot, when re-asking is free.
if let silenceIn {
	let takeURL = URL(fileURLWithPath: silenceIn).standardizedFileURL
	let directory = takeURL.deletingLastPathComponent()
	do {
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))

		// The separate recorder when there is one, with the take's offset
		// relating its clock to the video's — the same choice `Transcriber` and
		// `--speakers` make, because it is the better microphone and it is the
		// one the words were heard from. Everything printed below is on the
		// video's clock, like every time in a take file.
		let listenTo: URL
		let shift: Double
		if let audio = take.audio {
			listenTo = URL(fileURLWithPath: audio.file, relativeTo: directory).standardizedFileURL
			shift = take.video == nil ? 0 : audio.offset
		} else if let video = take.video {
			listenTo = URL(fileURLWithPath: video, relativeTo: directory).standardizedFileURL
			shift = 0
		} else {
			fail("that take has nothing to listen to")
		}

		let said: Transcript = take.words.flatMap { words in
			try? Transcript.read(String(
				contentsOf: URL(fileURLWithPath: words.path, relativeTo: directory),
				encoding: .utf8))
		} ?? Transcript()

		let wave = try await WaveformExtractor.extract(url: listenTo)
		let clock = Date()
		let map = SpeechMap.of(wave, shift: shift)
		// The decode is not counted. It is the expensive half and the timeline
		// has already paid for it; what is worth knowing is whether *this* is
		// cheap enough to ask again rather than write down, which is the whole
		// argument against a sidecar.
		let took = Date().timeIntervalSince(clock)

		/// The last few words to have finished by a moment, and the first few to
		/// start after one. What makes a list of gaps navigable: a stretch of
		/// quiet with nothing said around it is a number nobody can place.
		func before(_ time: Double, _ count: Int = 5) -> String {
			said.words.filter { $0.end <= time + 0.001 }.suffix(count)
				.map(\.text).joined(separator: " ")
		}
		func after(_ time: Double, _ count: Int = 5) -> String {
			said.words.filter { $0.start >= time - 0.001 }.prefix(count)
				.map(\.text).joined(separator: " ")
		}
		func fit(_ text: String, _ width: Int) -> String {
			let trimmed = text.isEmpty ? "\u{2014}" : text
			if trimmed.count <= width { return trimmed.padding(toLength: width, withPad: " ", startingAt: 0) }
			return String(trimmed.prefix(width - 1)) + "\u{2026}"
		}
		/// Right-aligned, because a column of times is read by its decimal
		/// point. `%10@` does not pad a Swift string, whatever it looks like.
		func at(_ time: Double, _ width: Int = 10) -> String {
			let written = Timecode.string(time)
			return String(repeating: " ", count: Swift.max(0, width - written.count)) + written
		}
		/// How a mark sits against the speech, said in one phrase.
		func standing(_ time: Double, air: Double) -> String {
			let inside = map.depthIntoSpeech(at: time)
			// A mark under a millisecond inside a run is on the edge of it, and
			// saying it cuts 0.000 s into the speech is a way of being precise
			// and wrong at the same time.
			if inside >= 0.001 { return String(format: "cuts %.3f s into speech", inside) }
			if inside > 0 { return "on the edge" }
			return String(format: "air %.3f s", air)
		}

		print("\(takeURL.deletingPathExtension().lastPathComponent)"
			+ " \u{2014} \(listenTo.lastPathComponent), \(Timecode.string(wave.duration))"
			+ (shift == 0 ? ", the video's own clock"
				: ", shifted \(Timecode.offsetString(shift)) onto the video's clock"))
		print(String(format: "%d runs of speech, %d stretches of quiet, %d words, %.0f ms to measure",
		             map.runs.count, map.quiet.count, said.count, took * 1000))
		print(String(format: "handle %.3f s, reach %.3f s", handle, SpeechMap.reach))
		print("a mark is put on the sound within the reach, then takes air up to the handle"
			+ " and never past the middle of the pause it is in \u{2014} so two clips cut either side"
			+ " of one gap meet exactly and cannot overlap")

		if spanAsked {
			let asked = Swift.min(spanFrom, spanTo) ... Swift.max(spanFrom, spanTo)
			let room = said.neighbours(of: asked)
			let cut = map.cut(from: asked.lowerBound, to: asked.upperBound,
			                  after: room.before, before: room.after, handle: handle)
			print("")
			print("asked   \(at(cut.asked.lowerBound)) \u{2192} \(at(cut.asked.upperBound))"
				+ String(format: "   (%.3f s)", cut.asked.upperBound - cut.asked.lowerBound))
			let words = said.text(covering: cut.asked, limit: 14)
			if !words.isEmpty { print("words   \(words)") }
			print("refined \(at(cut.refined.lowerBound)) \u{2192} \(at(cut.refined.upperBound))"
				+ String(format: "   in %+.3f s, out %+.3f s", cut.startMoved, cut.endMoved))
			print(String(format: "quiet   %.3f s before, %.3f s after \u{2014} took %.3f s and %.3f s",
			             cut.quietBefore, cut.quietAfter, cut.startHandle, cut.endHandle))
			print("cut     \(at(cut.span.lowerBound)) \u{2192} \(at(cut.span.upperBound))"
				+ String(format: "   (%.3f s)", cut.duration))
			exit(0)
		}

		if showClips {
			guard !take.clips.isEmpty else {
				print("")
				print("no clips in that take yet")
				exit(0)
			}
			print("")
			print("clips \u{2014} where each mark sits against the speech")
			print("  " + fit("slug", 22) + "        in         out  "
				+ fit("at the in", 26) + "  at the out")
			for clip in take.clips {
				print("  " + fit(clip.slug, 22) + "  " + at(clip.start) + "  " + at(clip.end) + "  "
					+ fit(standing(clip.start, air: map.quiet(before: clip.start)), 26)
					+ "  " + standing(clip.end, air: map.quiet(after: clip.end)))
			}
			exit(0)
		}

		print("")
		print("quiet")
		print("        from          to   length  " + fit("after", 34) + "  before")
		for gap in map.quiet {
			print("  " + at(gap.lowerBound) + "  " + at(gap.upperBound)
				+ String(format: "  %7.3f  ", gap.upperBound - gap.lowerBound)
				+ fit(before(gap.lowerBound), 34) + "  " + fit(after(gap.upperBound), 34))
		}
	} catch {
		fail(error.localizedDescription)
	}
	exit(0)
}

if let speakingIn {
	let takeURL = URL(fileURLWithPath: speakingIn).standardizedFileURL
	let directory = takeURL.deletingLastPathComponent()
	do {
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		guard let videoPath = take.video else { fail("that take has no video") }
		let video = URL(fileURLWithPath: videoPath, relativeTo: directory).standardizedFileURL
		let candidates = take.anchors.compactMap { anchor -> SpeakerDetector.Candidate? in
			guard let sidecar = anchor.path,
			      let text = try? String(
				      contentsOf: URL(fileURLWithPath: sidecar, relativeTo: directory), encoding: .utf8)
			else { return nil }
			return SpeakerDetector.Candidate(name: anchor.name, path: AnchorPath.read(text))
		}
		guard !candidates.isEmpty else { fail("that take has no solved anchors to tell apart") }
		let finding = try await SpeakerDetector.speaking(
			videoURL: video, among: candidates, from: spanFrom, to: spanTo)
		if let finding {
			print(String(format: "%@ — mouth moved %.4f per sample, %@ ahead of the next",
			             finding.name, finding.movement,
			             finding.margin.isFinite ? String(format: "%.2f\u{d7}", finding.margin) : "alone"))
		} else {
			print("nobody clearly talking between \(spanFrom)s and \(spanTo)s")
		}
	} catch {
		fail(error.localizedDescription)
	}
	exit(0)
}

if let facesOf {
	let url = URL(fileURLWithPath: facesOf).standardizedFileURL
	do {
		let faces = try await AnchorSolver.faces(videoURL: url, at: facesAt)
		if faces.isEmpty {
			print("no faces at \(facesAt)s")
		}
		for (index, face) in faces.enumerated() {
			func show(_ name: String, _ point: CGPoint?) -> String {
				guard let point else { return "\(name): —" }
				return String(format: "%@: [%.4f, %.4f]", name, point.x, point.y)
			}
			print(String(format: "face %d  box [%.3f %.3f %.3f %.3f]  %@  %@  %@",
			             index, face.boundingBox.minX, face.boundingBox.minY,
			             face.boundingBox.width, face.boundingBox.height,
			             show("left-eye", face.leftEye), show("right-eye", face.rightEye),
			             show("nose", face.nose)))
		}
	} catch {
		fail(error.localizedDescription)
	}
	exit(0)
}

guard let projectPath else { usage() }

let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
let baseURL = projectURL.deletingLastPathComponent()

let project: Project
do {
	project = try ProjectReader.read(try String(contentsOf: projectURL, encoding: .utf8))
} catch {
	fail(error.localizedDescription)
}

// Measuring before resolving, because resolving compares what the takes measured
// against what the project is aiming at.
//
// Per recording, not per clip: how loud a take is and what colour it is are
// facts about the recording, so one pass serves every programme that uses it —
// which is why the numbers are written back into the take rather than kept here.
if analyse {
	do {
		for path in project.takes {
			let takeURL = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
			var take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
			let directory = takeURL.deletingLastPathComponent()
			if !quiet { print("==> measuring \(takeURL.lastPathComponent)") }

			// The audio somebody will actually hear: the separate recorder when
			// there is one, because that is the reason it was recorded.
			let audioURL = take.audio.map { URL(fileURLWithPath: $0.file, relativeTo: directory) }
				?? take.video.map { URL(fileURLWithPath: $0, relativeTo: directory) }
			if let audioURL {
				// Only the spans this take contributes. Clip times are on the
				// video's clock; a separate recorder has a clock of its own, and
				// the take's offset is what relates them — the same number the
				// renderer uses to line the two up.
				let offset = take.audio.map { _ in take.audio!.offset } ?? 0
				let ranges = take.clips.map { clip in
					(clip.start - offset) ... (clip.end - offset)
				}
				let loudness = try await LoudnessMeter.measure(
					url: audioURL.standardizedFileURL, ranges: ranges)
				take.measured.loudness = loudness.integrated
				take.measured.peak = loudness.peak
				if !quiet {
					let level = loudness.integrated.map { String(format: "%.1f LUFS", $0) } ?? "silent"
					print(String(format: "    %@, peak %.1f dBFS", level, loudness.peak))
				}
			}

			if let videoPath = take.video {
				let video = URL(fileURLWithPath: videoPath, relativeTo: directory).standardizedFileURL
				// The same argument as the loudness: sampled across what the
				// take actually contributes, not across footage nobody will see.
				let duration = (try? await MediaProbe.probe(video).duration) ?? 0
				let from = take.clips.map(\.start).min() ?? 0
				let to = take.clips.map(\.end).max() ?? duration
				let cast = try await ColourAnalysis.measure(videoURL: video, from: from, to: to)
				take.measured.cast = cast
				if !quiet {
					print("    cast [" + cast.map { String(format: "%.4f", $0) }.joined(separator: ", ") + "]")
				}
			}

			try TakeWriter.write(take).write(to: takeURL, atomically: true, encoding: .utf8)
		}
	} catch {
		fail("measuring: \(error.localizedDescription)")
	}
}

// Solving before resolving, because resolving reads the sidecars.
//
// Anchors belong to the takes, so a re-solve rewrites sidecars beside the take
// files rather than beside the project — which is what makes a take carry its
// tracking into every programme that uses it.
if solve {
	do {
		for path in project.takes {
			let takeURL = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
			let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
			let takeDirectory = takeURL.deletingLastPathComponent()
			guard let videoPath = take.video else { continue }
			let video = URL(fileURLWithPath: videoPath, relativeTo: takeDirectory).standardizedFileURL
			var updated = take
			var changed = false
			for (index, anchor) in take.anchors.enumerated() {
				guard let sidecar = anchor.path else { continue }
				if !quiet { print("==> following \(anchor.name) in \(takeURL.lastPathComponent)") }
				// Follows the shot outward from the mark, the same as the
				// cutting window does, rather than trusting a range that may
				// have been written before the tracker had an opinion.
				let solved = try await AnchorSolver.solveShot(
					videoURL: video, method: anchor.method,
					markedAt: anchor.markedAt, point: anchor.point,
					// The whole recording, not the cut region: a shot reaches as
					// far as it reaches, and bounding it by where the clips
					// happen to be today is the coupling this change removed.
					within: 0 ... max((try? await MediaProbe.probe(video).duration) ?? 0, anchor.markedAt))
				let url = URL(fileURLWithPath: sidecar, relativeTo: takeDirectory)
				try FileManager.default.createDirectory(
					at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				if let range = solved.timeRange {
					updated.anchors[index].from = range.lowerBound
					updated.anchors[index].to = range.upperBound
					changed = true
					if !quiet {
						print("    \(Timecode.string(range.lowerBound)) to "
							+ "\(Timecode.string(range.upperBound)), \(solved.samples.count) samples")
					}
				}
				try solved.write(
					name: anchor.name,
					over: "\(Timecode.string(updated.anchors[index].from))–"
						+ "\(Timecode.string(updated.anchors[index].to))",
					framesPerSecond: project.output.framesPerSecond)
					.write(to: url, atomically: true, encoding: .utf8)
			}
			// The range the tracker found goes back into the take, so the next
			// run and the cutting window both know how far the shot reaches.
			if changed {
				try TakeWriter.write(updated).write(to: takeURL, atomically: true, encoding: .utf8)
			}
		}
	} catch {
		fail("solving: \(error.localizedDescription)")
	}
}

/// Where in the file something laid over the programme is written, when that is
/// not the top-level list.
///
/// Two captions with the same words over two uses of one clip are told apart by
/// nothing else, and "why is this one on here" is exactly the question
/// `--describe` is asked.
func writtenIn(_ origin: Origin, of project: Project, covering: Bool) -> String? {
	guard case .entry(let path, let index) = origin else { return nil }
	let entry = project.entry(at: path)
	return "           written in `\(entry?.source.description ?? "?")`"
		+ " at timeline \(path.map(String.init).joined(separator: "."))"
		+ ", number \(index + 1)"
		+ (covering ? " — covering that placement" : "")
}

let resolved: ResolvedProject
do {
	resolved = try Resolver.resolve(project, baseURL: baseURL)
} catch {
	fail(error.localizedDescription)
}

if describe {
	// What was skipped, before what was kept: a warning after two hundred lines
	// of programme is a warning nobody reads.
	for warning in resolved.warnings {
		FileHandle.standardError.write("warning: \(warning)\n".data(using: .utf8)!)
	}
	print("clips")
	for clip in resolved.clips {
		print(String(format: "  %-28@ %7.3f → %7.3f  %@",
		             clip.reference.description as NSString, clip.start, clip.end,
		             clip.takeName as NSString))
	}
	if !resolved.cards.isEmpty {
		print("cards")
		for card in resolved.cards {
			let fill: String
			switch card.card.fill {
			case .solid(let colour): fill = colour.hex
			case .gradient(let top, let bottom): fill = "\(top.hex) → \(bottom.hex)"
			}
			print(String(format: "  %-28@ %7.3f → %7.3f", fill as NSString, card.start, card.end))
		}
	}
	if !resolved.sounds.isEmpty {
		print("sounds")
		for sound in resolved.sounds {
			var says = String(format: "%.1f dB", sound.sound.gain)
			if sound.sound.fadeIn > 0 { says += String(format: ", in %.2fs", sound.sound.fadeIn) }
			if sound.sound.fadeOut > 0 { says += String(format: ", out %.2fs", sound.sound.fadeOut) }
			if sound.sound.ducks != 0 { says += String(format: ", ducks %.1f dB", sound.sound.ducks) }
			print(String(format: "  %7.3f → %7.3f  %@  (%@)", sound.start, sound.end,
			             sound.sound.file as NSString, says as NSString))
			if let where_ = writtenIn(sound.origin, of: project,
			                          covering: sound.sound.span == nil) {
				print(where_)
			}
		}
	}
	print("anchors")
	for entry in resolved.anchors {
		let samples = entry.path?.samples.count ?? 0
		print("  \(entry.anchor.name): \(samples) samples"
			+ (entry.path == nil ? "  — NO PATH: nothing will follow it" : ""))
	}
	print("overlays")
	for shown in resolved.overlays {
		let what: String
		switch shown.overlay.kind {
		case .scene(let name, let parameters):
			what = "scene \(name)" + (parameters.isEmpty ? "" : " \(parameters)")
		case .effect(let effect):
			what = "effect \(effect.style.rawValue) ×\(effect.count) seed \(effect.seed)"
		case .film(let film):
			what = "film \(film.tint.rawValue) \(film.ratio.written)"
				+ " grain \(film.grain) vignette \(film.vignette)"
		case .aberration(let aberration):
			what = "aberration \(aberration.kind.rawValue) amount \(aberration.amount)"
				+ (aberration.kind == .linear ? " angle \(aberration.angle)" : "")
		case .tape(let tape):
			what = "tape \(tape.condition.rawValue) jitter \(tape.jitter) band \(tape.band)"
				+ " chroma \(tape.chroma) scanlines \(tape.scanlines)"
				+ " dropouts \(tape.dropouts) seed \(tape.seed)"
		case .text(let text, let style):
			what = "text \(text.debugDescription) style \(style ?? "lower-third")"
		case .spinner(let spinner):
			what = "spinner \(spinner.style.rawValue) size \(spinner.size)"
				+ (spinner.words.isEmpty ? " (no words)"
					: " words \(spinner.words.map(\.text).joined(separator: " · "))")
		case .bubble(let bubble):
			what = "bubble \(bubble.shape.rawValue) \(bubble.text.debugDescription)"
				+ " seed \(bubble.seed) width \(bubble.width)"
				+ (bubble.breath == 1 ? "" : bubble.breath == 0
					? " still" : " breath \(bubble.breath)")
				+ (bubble.at.map { " at [\($0.x), \($0.y)]" } ?? "")
				+ (bubble.tail == .zero ? ""
					: " tail [\(bubble.tail.x), \(bubble.tail.y)]")
				+ (bubble.follow ? "" : " pinned")
		case .frames(let frames):
			// The one overlay whose contents are outside the project file, so
			// this is where somebody finds out that the folder is empty or that
			// the render they ran stopped half way. A `.cuttrproj` cannot say how
			// many pictures there ought to be; the folder is the only witness.
			let found = frames.found(relativeTo: resolved.baseURL)
			what = "frames \(frames.folder) at \(frames.framesPerSecond) fps"
				+ " size \(frames.size) \(frames.ends.rawValue)"
				+ (found.count == 0
					? "  — NO PICTURES IN THAT FOLDER: nothing will be drawn"
					: String(format: "  — %d frames, %d×%d, %.2fs", found.count,
					         Int(found.pixels.width), Int(found.pixels.height),
					         found.seconds))
		}
		/// Where a movement sits, said only when it is not where it usually
		/// sits — the defaults differ between the two ends, and printing them
		/// would be noise on every line of every project.
		func placed(
			_ placement: Overlay.Transition.Placement,
			_ usual: Overlay.Transition.Placement
		) -> String {
			placement == usual ? "" : " at \(placement.rawValue)"
		}
		print(String(format: "  %7.3f → %7.3f  %@", shown.start, shown.end, what as NSString))
		if let where_ = writtenIn(shown.origin, of: project,
		                          covering: shown.overlay.appearances.isEmpty) {
			print(where_)
		}
		print("           anchor \(shown.overlay.anchor ?? "none")"
			+ (shown.overlay.anchor != nil && shown.path == nil
				? "  — NOT FOUND: it will sit where its style says" : "")
			+ "  in \(shown.overlay.arrival)\(placed(shown.overlay.arrivalPlacement, .after))"
			+ "  out \(shown.overlay.departure)\(placed(shown.overlay.departurePlacement, .before))")
	}
	exit(0)
}

// `-o`, then the project's own `output.file`, then the project's name. A
// project that says where it goes should render with no arguments at all.
let outputURL: URL = {
	if let outputPath { return URL(fileURLWithPath: outputPath).standardizedFileURL }
	if let file = project.output.file {
		return URL(fileURLWithPath: file, relativeTo: baseURL).standardizedFileURL
	}
	return projectURL.deletingPathExtension().appendingPathExtension("mov")
}()

if !quiet {
	print("==> \(resolved.clips.count) clips, \(String(format: "%.1f", resolved.duration))s, "
		+ "\(resolved.overlays.count) overlays → \(outputURL.lastPathComponent)")
}

// A progress line that rewrites itself, and only when somebody is watching:
// piped into a log, `\r` would produce one enormous line.
let interactive = isatty(STDERR_FILENO) == 1 && !quiet
do {
	try await Renderer.export(resolved, to: outputURL) { fraction in
		guard interactive else { return }
		let width = 40
		let filled = Int(fraction * Double(width))
		let bar = String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
		FileHandle.standardError.write(
			"\r    \(bar) \(Int(fraction * 100))%".data(using: .utf8)!)
	}
} catch {
	if interactive { FileHandle.standardError.write("\n".data(using: .utf8)!) }
	fail(error.localizedDescription)
}
if interactive { FileHandle.standardError.write("\n".data(using: .utf8)!) }
if !quiet { print("==> wrote \(outputURL.path)") }
