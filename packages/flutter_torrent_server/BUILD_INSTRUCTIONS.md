# Building the Native Torrent Server

The Go source under `go_src/` is **not** what ships. The app loads prebuilt
binaries committed to this repo, so a change under `go_src/` reaches users only
after `build_libs.sh` has run and the regenerated artifacts have been committed.

## Prerequisites

1. **Go 1.26+** — [download](https://go.dev/dl/). `go_src/go.mod` pins
   `toolchain go1.26.8`, which the go command fetches on demand, so a slightly
   older local Go is fine as long as it understands the directive.
2. **A JDK on `PATH`** — `gomobile bind` shells out to `javac`, and fails with
   "Unable to locate a Java Runtime" without one. Android Studio's bundled
   runtime works:
   ```bash
   export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   export PATH="$JAVA_HOME/bin:$PATH"
   ```
3. **gomobile and gobind** (Android and iOS):
   ```bash
   go install golang.org/x/mobile/cmd/gomobile@latest
   go install golang.org/x/mobile/cmd/gobind@latest
   ```
4. **Android NDK** — installed through Android Studio. The script defaults to
   `$ANDROID_HOME/ndk/27.0.12077973`.
5. **Xcode** — only for the iOS xcframework, which the script skips off macOS.

## Build script

```bash
cd packages/flutter_torrent_server
./build_libs.sh
```

It regenerates every shipped artifact:

| Artifact | Path |
| --- | --- |
| Desktop executables (6 targets) | `assets/torrserver/TorrServer-*` |
| Android AAR, reference copy | `go_src/torrserver.aar` |
| Android AAR, the one Gradle resolves | `android/repo/com/local/torrentserver/1.0/torrentserver-1.0.aar` |
| iOS xcframework | `ios/TorrServer.xcframework` |

Desktop binaries build from `go_src` with its vendored dependencies
(`-mod=vendor`), so they are reproducible from what is committed. The mobile
bind runs against a throwaway copy of the tree instead, because `gomobile`
imports `golang.org/x/mobile/bind`, which is not vendored here — that keeps
`go_src/go.mod` exactly as committed, at the cost of the mobile artifacts
resolving a slightly newer dependency set than the desktop ones.

## 16 KB page size (Android)

The Android bind passes `-extldflags=-Wl,-z,max-page-size=16384`, which aligns
`libgojni.so`'s LOAD segments for 16 KB page-size devices (Android 15+). The Go
linker still defaults to 4 KB, and a single 4 KB-aligned library puts the whole
app into page-size compatibility mode. To verify after a rebuild:

```bash
OBJD=$ANDROID_HOME/ndk/27.0.12077973/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-objdump
unzip -o android/repo/com/local/torrentserver/1.0/torrentserver-1.0.aar -d /tmp/aar
for abi in armeabi-v7a arm64-v8a x86 x86_64; do
  echo "$abi $($OBJD -p /tmp/aar/jni/$abi/libgojni.so | grep -m1 -o 'align 2\*\*[0-9]*')"
done
```

Every ABI must report `2**14` or higher.

## Engine version

`go_src/go.mod` pins the BitTorrent engine through a replace directive:

```
replace github.com/anacrolix/torrent v1.59.1 => github.com/tsynik/torrent v1.2.31
```

`tsynik/torrent` is the fork upstream TorrServer ships; keeping the same version
as the current TorrServer release is the cheapest way to pick up its crash and
deadlock fixes. To move it, edit both the `replace` and the `require` line to
the version pair upstream uses, then:

```bash
cd go_src && go mod tidy && go mod vendor
go build -mod=vendor ./cmd/torrserver && go test -mod=vendor ./...
```

## Checking for vulnerable dependencies

```bash
cd go_src && go run golang.org/x/vuln/cmd/govulncheck@latest -mode=source ./...
```

This reports only advisories your code actually reaches. Standard-library
findings are fixed by raising the `toolchain` line in `go.mod`; module findings
by bumping the dependency and re-vendoring.
