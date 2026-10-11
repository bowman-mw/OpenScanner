#!/bin/zsh
# Builds and runs the GlareFusion harness on macOS from the app's own sources: PageCleanup.swift
# and GlareFusion.swift verbatim, and PageDetector extracted verbatim from CaptureCamera.swift
# between its MARK lines. Writes PNGs and summary.txt to the output folder.
#
# Usage: Tools/GlareFusionHarness/run.sh [output-dir]   (default: $TMPDIR/glare-fusion-harness)
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h:h}
SRC="$ROOT/scanner/Capture"
OUT=${1:-"${TMPDIR:-/tmp}/glare-fusion-harness"}
BUILD="$OUT/build"
mkdir -p "$BUILD"
{
	echo "import CoreGraphics"
	echo "import CoreVideo"
	echo "import ImageIO"
	echo "import Vision"
	sed -n '/^\/\/ MARK: - PageDetector$/,/^\/\/ MARK: - QuadStabilityTracker$/p' "$SRC/CaptureCamera.swift" | sed '$d'
} > "$BUILD/PageDetector.extracted.swift"
xcrun swiftc -O -swift-version 5 -o "$BUILD/harness" \
	"$SRC/PageCleanup.swift" "$SRC/GlareFusion.swift" "$BUILD/PageDetector.extracted.swift" "$HERE"/*.swift
"$BUILD/harness" "$OUT"
