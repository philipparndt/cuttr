import Foundation

/// ai-connector on this computer: where it says it is, and how to get it there.
///
/// The assistant talks to somebody's *own* AI — [ai-connector][repo], which
/// runs Claude Code and local models on their machine. It needs no setting up
/// from this side: while it runs it keeps a small file saying where it listens
/// and with what token, and reading that file is the whole of discovery.
///
/// When the file is not there, the answer is not a form. It is one command,
/// shown to be copied, that downloads the newest release, checks it, and starts
/// it now and at every login — after which the file appears and the chat finds
/// it by itself.
///
/// [repo]: https://github.com/philipparndt/ai-connector
public enum Connector {

	/// ai-connector's configuration folder: `$MLXLAB_HOME`, else
	/// `$XDG_CONFIG_HOME/mlxlab`, else `~/.config/mlxlab`. Its rule, not ours —
	/// this has to look where it writes.
	public static func directory(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		home: String = NSHomeDirectory()
	) -> URL {
		if let own = environment["MLXLAB_HOME"], !own.isEmpty {
			return URL(fileURLWithPath: own, isDirectory: true)
		}
		if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
			return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("mlxlab")
		}
		return URL(fileURLWithPath: home, isDirectory: true)
			.appendingPathComponent(".config").appendingPathComponent("mlxlab")
	}

	/// The file a running connector keeps: `{"url", "token", "pid"}`.
	public static func discoveryFile(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		directory(environment: environment).appendingPathComponent("local-ai.json")
	}

	/// What the discovery file says.
	public struct Discovery: Equatable, Sendable, CustomDebugStringConvertible {
		public var url: String
		public var token: String
		public var pid: Int?

		/// Never the token. This ends up in logs and in test failures.
		public var debugDescription: String { "Discovery(url: \(url), pid: \(pid.map(String.init) ?? "-"))" }
	}

	public enum DiscoveryError: LocalizedError, Equatable {
		case malformed(String)

		public var errorDescription: String? {
			switch self {
			case .malformed(let path): return "\(path) names no url or no token"
			}
		}
	}

	/// Reads the discovery file. `nil` when there is none, which is the
	/// ordinary state of a machine nobody has set this up on.
	///
	/// A file that is there and broken is an error rather than "none": saying
	/// "not set up" to somebody who has set it up sends them to run a command
	/// that will not help.
	public static func discovery(at file: URL = discoveryFile()) throws -> Discovery? {
		guard let data = try? Data(contentsOf: file) else { return nil }
		let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		guard let url = object?["url"] as? String, !url.isEmpty,
		      let token = object?["token"] as? String, !token.isEmpty
		else { throw DiscoveryError.malformed(file.path) }
		return Discovery(url: url, token: token, pid: object?["pid"] as? Int)
	}

	// MARK: - Setting it up

	/// `text` as one word for a POSIX shell.
	public static func shellQuote(_ text: String) -> String {
		let plain = CharacterSet(charactersIn:
			"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=@%+,-")
		if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
		return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	/// Puts the setup script where it can be run, and says where.
	///
	/// A file rather than a `curl … | sh` line: what somebody is asked to run is
	/// then something they can open and read first, and it does not depend on a
	/// second server being up to hand the script over.
	public static func writeSetupScript(into folder: URL) throws -> URL {
		let file = folder.appendingPathComponent("ai-setup.sh")
		if (try? String(contentsOf: file, encoding: .utf8)) != setupScript {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try setupScript.write(to: file, atomically: true, encoding: .utf8)
		}
		return file
	}

	/// The one line to paste into a terminal.
	public static func setupCommand(script: URL) -> String {
		"sh " + shellQuote(script.path)
	}

	/// Downloads the newest ai-connector release, checks it against the
	/// release's own checksums, and runs `ai-connector local --install`.
	///
	/// The same script OpenSolve and OpenCAD hand out, so a machine set up for
	/// one of them is set up for all three — it is one connector and one
	/// discovery file, whoever asked for it first.
	public static let setupScript = #"""
	#!/bin/sh
	# cuttr: sets up the local AI (ai-connector) on macOS.
	#
	# Downloads the newest ai-connector release from GitHub into
	# ~/.local/share/ai-connector (AI_CONNECTOR_DIR overrides it), checks the
	# archive against the release's SHA256SUMS, and runs
	# `ai-connector local --install`: it starts now and at every login, and
	# cuttr finds it by itself. Run it again to update; an installed current
	# version is not downloaded again.
	set -eu

	repo=philipparndt/ai-connector
	dir=${AI_CONNECTOR_DIR:-"$HOME/.local/share/ai-connector"}

	fail() {
	    echo "ai-setup: $*" >&2
	    exit 1
	}

	command -v curl >/dev/null 2>&1 || fail "curl is missing"
	command -v tar >/dev/null 2>&1 || fail "tar is missing"

	case "$(uname -s)" in
	Darwin) os=darwin ;;
	Linux) os=linux ;;
	*) fail "no ai-connector release for $(uname -s)" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	arm64 | aarch64) arch=arm64 ;;
	*) fail "no ai-connector release for $(uname -m)" ;;
	esac
	# A shell under Rosetta reports x86_64 on Apple silicon.
	if [ "$os" = darwin ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
	    arch=arm64
	fi
	[ "$os/$arch" != darwin/amd64 ] || fail "ai-connector needs a Mac with Apple silicon"

	# The newest release: the redirect of /releases/latest, else the API.
	latest=$(curl -fsSL --connect-timeout 15 -o /dev/null -w '%{url_effective}' \
	    "https://github.com/$repo/releases/latest" 2>/dev/null || true)
	v=${latest##*/tag/}
	case "$v" in
	v[0-9]*) ;;
	*)
	    v=$(curl -fsSL --connect-timeout 15 "https://api.github.com/repos/$repo/releases/latest" |
	        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
	    ;;
	esac
	[ -n "$v" ] || fail "cannot find the newest release of $repo"

	exe="$dir/ai-connector"
	have=""
	if [ -x "$exe" ]; then
	    have=$("$exe" version 2>/dev/null || true)
	fi

	if [ "$have" = "$v" ]; then
	    echo "ai-connector $v is up to date in $dir"
	else
	    name="ai-connector-$v-$os-$arch"
	    base="https://github.com/$repo/releases/download/$v"
	    tmp=$(mktemp -d)
	    trap 'rm -rf "$tmp"' EXIT
	    trap 'exit 1' INT TERM
	    echo "Downloading ai-connector $v ($os-$arch)…"
	    curl -fsSL --connect-timeout 15 -o "$tmp/$name.tar.gz" "$base/$name.tar.gz" ||
	        fail "download failed: $base/$name.tar.gz"
	    if curl -fsSL --connect-timeout 15 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" 2>/dev/null; then
	        want=$(awk -v f="$name.tar.gz" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
	        [ -n "$want" ] || fail "SHA256SUMS lists no $name.tar.gz"
	        if command -v sha256sum >/dev/null 2>&1; then
	            got=$(sha256sum "$tmp/$name.tar.gz" | awk '{ print $1 }')
	        else
	            got=$(shasum -a 256 "$tmp/$name.tar.gz" | awk '{ print $1 }')
	        fi
	        [ "$got" = "$want" ] || fail "checksum mismatch for $name.tar.gz"
	        echo "SHA-256 checked"
	    else
	        echo "The release has no SHA256SUMS: not checked"
	    fi
	    tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
	    [ -d "$tmp/$name" ] || fail "unexpected archive layout"
	    mkdir -p "$dir"
	    # Copy beside, then rename: a running ai-connector keeps its old file.
	    for f in "$tmp/$name"/*; do
	        n=$(basename "$f")
	        cp "$f" "$dir/.$n.new"
	        mv -f "$dir/.$n.new" "$dir/$n"
	    done
	    if [ "$os" = darwin ]; then
	        xattr -d com.apple.quarantine "$exe" 2>/dev/null || true
	    fi
	    echo "Installed ai-connector $("$exe" version 2>/dev/null || echo "$v") in $dir"
	fi

	"$exe" local --help >/dev/null 2>&1 || fail "$exe has no “local” command"
	"$exe" local --install
	echo "Done: ai-connector runs now and at every login. cuttr finds it by itself."

	"""#
}
