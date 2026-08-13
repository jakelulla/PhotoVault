#!/bin/bash
# Build (or rebuild) the photo search index over ../test_images.
# Slow, one-time CPU pass: detects faces, clusters people, computes CLIP
# embeddings, and extracts timestamps. Preserves names.json across rebuilds.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

exec ./venv/bin/python build_index.py
