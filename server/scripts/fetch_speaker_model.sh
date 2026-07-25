#!/usr/bin/env bash
# Fetches the WeSpeaker ECAPA-TDNN-512 (LM) speaker-embedding ONNX model used by
# App.Speaker.Ortex. Not committed (priv/models/ is gitignored) — run this after
# clone/deploy to populate priv/models/speaker_ecapa.onnx.
#
# Source: Hugging Face `Wespeaker/wespeaker-ecapa-tdnn512-LM`, file
# voxceleb_ECAPA512_LM.onnx (route (a) from the voice-lock spike — task 0).
set -euo pipefail

DEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/priv/models"
DEST="$DEST_DIR/speaker_ecapa.onnx"
URL="https://huggingface.co/Wespeaker/wespeaker-ecapa-tdnn512-LM/resolve/main/voxceleb_ECAPA512_LM.onnx"

mkdir -p "$DEST_DIR"
echo "Fetching WeSpeaker ECAPA-512 (LM) ONNX model to $DEST ..."
curl -fL --retry 3 -o "$DEST" "$URL"

echo "sha256: $(shasum -a 256 "$DEST" | awk '{print $1}')"
echo "Done: $DEST"
