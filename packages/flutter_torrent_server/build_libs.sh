#!/bin/bash
#
# Regenerates every prebuilt artifact in this package from go_src/.
#
# THE GO SOURCE IS NOT WHAT SHIPS. The app loads prebuilt binaries that are
# committed to the repo, so a change under go_src/ reaches users only after
# this script has run and the artifacts below have been committed:
#
#   assets/torrserver/TorrServer-*                        desktop (6 targets)
#   go_src/torrserver.aar                                 Android, reference copy
#   android/repo/com/local/torrentserver/1.0/…-1.0.aar    Android, the one Gradle resolves
#   ios/TorrServer.xcframework                            iOS
#
# Requirements: Go, Xcode (for iOS), Android NDK, and gomobile/gobind on PATH
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   go install golang.org/x/mobile/cmd/gobind@latest
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$ROOT/go_src"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.0.12077973}"
export PATH="$PATH:$HOME/go/bin"

echo "Building Torrent Server Libraries..."

# ---------------------------------------------------------------------------
# 1. Desktop standalone binaries.
#
# Built straight out of go_src with its vendored dependencies, so these are
# reproducible from what is committed. No `go mod tidy` — that would silently
# move the pinned dependency set.
# ---------------------------------------------------------------------------
echo "Building desktop binaries..."
mkdir -p "$ROOT/assets/torrserver"
build_desktop() {
  echo "  $3"
  ( cd "$SRC_DIR" && CGO_ENABLED=0 GOOS="$1" GOARCH="$2" \
      go build -mod=vendor -o "$ROOT/assets/torrserver/$3" ./cmd/torrserver )
}
build_desktop darwin  amd64 TorrServer-darwin-amd64
build_desktop darwin  arm64 TorrServer-darwin-arm64
build_desktop linux   amd64 TorrServer-linux-amd64
build_desktop linux   arm64 TorrServer-linux-arm64
build_desktop windows amd64 TorrServer-windows-amd64.exe
build_desktop windows arm64 TorrServer-windows-arm64.exe

# ---------------------------------------------------------------------------
# 2. Mobile artifacts.
#
# gomobile has to import golang.org/x/mobile/bind, which is not one of this
# module's dependencies and is not vendored. Adding it to go.mod would drag
# x/tools and a Go toolchain bump into the vendored tree that the desktop
# binaries are built from, so the bind runs against a throwaway copy instead
# and go_src/go.mod is left exactly as committed.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar cf - -C "$SRC_DIR" \
  --exclude=vendor --exclude=.gradle --exclude=torrserver.aar --exclude='*_test.go' . \
  | ( cd "$WORK" && tar xf - )
( cd "$WORK" && go get golang.org/x/mobile/bind && gomobile init )

echo "Building Android AAR..."
# ./bindings is package torrServer -> torrServer.TorrServer.startTorrentServer
#
# max-page-size=16384 aligns libgojni.so's LOAD segments for 16 KB page-size
# devices (Android 15+). The Go linker still defaults to 4 KB, and one
# 4 KB-aligned library puts the whole app into page-size compatibility mode.
( cd "$WORK" && gomobile bind -target=android -androidapi 21 \
    -ldflags="-s -w -extldflags=-Wl,-z,max-page-size=16384" \
    -o "$ROOT/go_src/torrserver.aar" ./bindings )
cp "$ROOT/go_src/torrserver.aar" \
   "$ROOT/android/repo/com/local/torrentserver/1.0/torrentserver-1.0.aar"

if [[ "$OSTYPE" == "darwin"* ]]; then
  echo "Building iOS xcframework..."
  # "." is package server -> ServerStart(pathdb, port, authToken, roSets, searchWA)
  rm -rf "$ROOT/ios/TorrServer.xcframework"
  ( cd "$WORK" && gomobile bind -target=ios,iossimulator -ldflags="-s -w" \
      -o "$ROOT/ios/TorrServer.xcframework" . )
else
  echo "Skipping iOS build (not on macOS)"
fi

echo "All builds finished."
