#!/usr/bin/env bash
#
# Renders one Remotion composition into a folder of numbered PNGs, in the shape
# a cuttr `frames:` overlay reads, and writes a sidecar saying what produced
# them.
#
#     tools/remotion/render.sh chart
#     tools/remotion/render.sh route examples/frames/route
#
# Nothing in cuttr runs this. It is not in `make`, it is not in the test suite,
# and a machine with no Node on it still builds cuttr and still renders every
# project whose frames are already on disk. That separation is the whole point —
# see `docs/remotion.md`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

composition="${1:-}"
if [ -z "$composition" ]; then
	echo "usage: render.sh <composition> [output-folder]" >&2
	echo "       compositions: chart, route" >&2
	exit 2
fi
out="${2:-$root/examples/frames/$composition}"

if ! command -v node >/dev/null 2>&1; then
	echo "render.sh needs Node 18 or later on the PATH. Nothing else in cuttr does." >&2
	exit 1
fi
if [ ! -d "$here/node_modules" ]; then
	echo "==> npm install (a few hundred megabytes, and a Chromium the first time)"
	(cd "$here" && npm install)
fi

# Rendered to one side and moved into place, for two reasons.
#
# A sequence is "the numbered pictures in the folder", so a folder half way
# through a render is a shorter sequence rather than a broken one — which is the
# right answer for an interrupted render and the wrong one for a render that is
# still going. Staging makes the folder appear finished or not at all. It also
# means leftovers from a longer previous render cannot be read as extra frames
# on the end.
#
# And it works around a Remotion refusal: `remotion render --sequence` will not
# write into any path with a dot in it — `extname()` of the resolved directory
# has to be empty — which rules out a checkout under, say, `~/.local/src`.
staging="${TMPDIR:-/tmp}/cuttr-frames-$composition"
rm -rf "$staging"
mkdir -p "$staging"

# `--sequence` writes `element-0000.png`, `element-0001.png`, … which is
# Remotion's default naming and is left alone on purpose: cuttr reads whatever
# numbered files it finds, so there is nothing to agree about here.
#
# `--image-format=png` is the only one of these that is not optional. A sequence
# laid over a shot needs an alpha channel, and JPEG has none — the chart would
# arrive as a white rectangle.
flags=(--sequence --image-format=png --log=info)
command=(npx --no-install remotion render src/index.ts "$composition" "$staging" "${flags[@]}")
# What goes in the sidecar names the folder the frames end up in, not the one
# they were staged through: the sidecar is a reproduction recipe, and staging is
# this script's business.
recorded="npx remotion render src/index.ts $composition $out ${flags[*]}"
echo "==> ${command[*]}"
(cd "$here" && "${command[@]}")

count=$(find "$staging" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')
if [ "$count" -eq 0 ]; then
	echo "no frames were written to $staging" >&2
	exit 1
fi

rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$staging" "$out"

# The sidecar. cuttr never reads it — a `frames:` overlay reads pictures and
# nothing else — and it exists so that somebody looking at a folder of PNGs in
# six months can find out what made them. Which is the honest version of the
# reproducibility problem `docs/remotion.md` sets out: these frames depend on a
# Chromium build and a `node_modules` tree, and the least this can do is write
# down which.
sources=$(cd "$here" && shasum -a 256 src/*.ts src/*.tsx remotion.config.ts package.json \
	| awk '{ printf "    \"%s\": \"%s\"%s\n", $2, $1, (NR>0 ? "," : "") }')
lock="none"
if [ -f "$here/package-lock.json" ]; then
	lock=$(shasum -a 256 "$here/package-lock.json" | awk '{ print $1 }')
fi
remotion=$(cd "$here" && node -e 'process.stdout.write(require("./package.json").dependencies.remotion)')

cat > "$out/rendered.json" <<JSON
{
  "composition": "$composition",
  "frames": $count,
  "remotion": "$remotion",
  "node": "$(node --version)",
  "command": "$recorded",
  "lockfile-sha256": "$lock",
  "source-sha256": {
$(printf '%s' "$sources" | sed '$ s/,$//')
  },
  "rendered": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

echo "==> $count frames in $out"
echo "    reference them from a project as, for instance:"
echo ""
echo "      - frames: $(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$out" "$(dirname "$out")")"
echo "        fps:    30"
echo ""
