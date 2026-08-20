#!/bin/bash
#
# Fetches a speaker-embedding model, so that cuttr can propose who is speaking.
#
# This is a separate script, run by hand, and that is the point. cuttr ships no
# model, downloads nothing by itself, and works completely without one — the
# automatic pass is an offer, and the two methods that need no model are always
# there. A model has a licence, and a licence is a decision somebody makes about
# their own work, not a decision a build script makes for them.
#
# Nothing about this changes what happens at transcription time. The model runs
# through Core ML, on this machine, on audio that never leaves it.

set -euo pipefail

DEST="${HOME}/Library/Application Support/cuttr/models"
NAME="voxceleb_resnet34_LM"
ONNX_URL="https://wenet.org.cn/downloads?models=wespeaker&version=${NAME}.onnx"

cat <<'LICENCE'
────────────────────────────────────────────────────────────────────────────
  What this fetches, and under what terms

  WeSpeaker voxceleb_resnet34_LM — a ResNet34 speaker-embedding network,
  about 26 MB, from the WeSpeaker project (github.com/wenet-e2e/wespeaker).

  Code and weights: Apache License 2.0.

  BUT READ THIS. The weights were trained on VoxCeleb, a corpus collected
  from YouTube whose own release terms are for non-commercial research. The
  authors publish the resulting weights under Apache-2.0; whether that
  reaches your use of them is a question about your work and not one this
  script can answer. If cuttr's output is going anywhere commercial, that is
  the sentence to read twice.

  Also worth knowing before you spend the download: VoxCeleb is adult
  speech, largely English, from broadcast interviews. A child's voice is
  outside what it was trained on, and the accuracy it advertises is not the
  accuracy you should expect on a seven-year-old.

  Alternatives, if those terms do not suit:
    · SpeechBrain spkrec-ecapa-voxceleb — Apache-2.0, same VoxCeleb caveat,
      PyTorch only, so converting needs torch and speechbrain installed.
    · NVIDIA NeMo TitaNet-Large — CC-BY-4.0, attribution required.
    · Your own, trained on your own recordings, with no caveat at all.

  Any of them will do: cuttr wants a compiled Core ML model that takes a mono
  16 kHz waveform and returns one vector. See Sources/CuttrKit/SpeakerEmbedding.swift.
────────────────────────────────────────────────────────────────────────────
LICENCE

read -r -p "Fetch it? [y/N] " answer
case "${answer}" in
	y | Y | yes | YES) ;;
	*) echo "Nothing fetched."; exit 0 ;;
esac

if ! python3 -c 'import coremltools' 2>/dev/null; then
	echo
	echo "This needs coremltools to turn the ONNX into a Core ML model:"
	echo "    python3 -m pip install --user coremltools onnx"
	echo
	echo "Nothing has been downloaded."
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> Downloading ${NAME}.onnx"
curl -fL --progress-bar -o "${WORK}/model.onnx" "${ONNX_URL}"

echo "==> Converting to Core ML"
python3 - "${WORK}" <<'PYTHON'
import sys, coremltools as ct
work = sys.argv[1]
model = ct.converters.onnx.convert(model=work + "/model.onnx", minimum_ios_deployment_target="13")
model.save(work + "/speaker-embedding.mlpackage")
PYTHON

echo "==> Compiling"
xcrun coremlcompiler compile "${WORK}/speaker-embedding.mlpackage" "${WORK}"

mkdir -p "${DEST}"
rm -rf "${DEST}/speaker-embedding.mlmodelc"
mv "${WORK}/speaker-embedding.mlmodelc" "${DEST}/"

# The terms go beside the model, because a model whose licence nobody can find
# is a model nobody can ship. cuttr shows this file wherever it offers the
# method.
cat > "${DEST}/LICENCE.txt" <<LICENCE
WeSpeaker ${NAME}
Apache License 2.0 — https://github.com/wenet-e2e/wespeaker

Trained on VoxCeleb, whose own release terms are for non-commercial research.
Fetched by Scripts/fetch-speaker-model.sh on $(date -u +%Y-%m-%d).
LICENCE

echo
echo "==> Done: ${DEST}/speaker-embedding.mlmodelc"
echo "    Terms: ${DEST}/LICENCE.txt"
echo "    cuttr will now offer \"Speaker embedding\" beside the other methods."
