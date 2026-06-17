# maplibre_flutter

> ⚠️ **Work in progress — not usable yet.** Early scaffolding. The public API is taking
> shape but **no platform renders a map yet** (`createMap()` throws `UnimplementedError`
> everywhere). Do **not** depend on it. No pub.dev release. APIs will break without
> notice. Watch/star for progress.

A Flutter plugin to render [MapLibre](https://maplibre.org) vector maps **natively on
every platform** — Android, iOS, macOS, Windows, Linux, and Web.

The differentiator versus existing packages (`maplibre_gl`, `maplibre`) is **true native
rendering on desktop** instead of a `maplibre-gl-js` WebView. On desktop we drive the
MapLibre Native C++ core (`mbgl-core`) directly and composite through Flutter's texture
pipeline. **Goal:** become the *stable*, well-tested MapLibre binding for Flutter.

### Status

| Piece                                                         | State                                     |
| ------------------------------------------------------------- | ----------------------------------------- |
| Federated monorepo + pub workspace + melos                    | ✅ scaffolded                              |
| Platform interface + `MapLibreMap` widget                     | ✅ skeleton (resolves / analyzes / tests)  |
| Per-platform impls (Android, iOS, macOS, Windows, Linux, Web) | 🚧 stubs — `createMap()` unimplemented     |
| `mbgl-core` submodule + C shim                                | ❌ not started (still template `sum` shim) |

See [`CLAUDE.md`](CLAUDE.md) for architecture decisions and the decision log.

---

## Running the example

The example app lives at `packages/maplibre_flutter/example`:

```bash
cd packages/maplibre_flutter/example
flutter run -d <android|ios|macos|windows|linux|chrome>
```

### iOS & macOS codesigning (local setup)

To avoid committing personal Apple Development Team IDs, the example injects signing
config from a local, git-ignored file instead of the Xcode project.

To run the example on a **physical iOS device**:

1. Create a local config file (already ignored by Git):
   - `packages/maplibre_flutter/example/ios/Flutter/Local.xcconfig`

2. Add your Apple Development Team ID:
   ```properties
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   ```
   Replace `YOUR_TEAM_ID` with your 10-character Team ID from the Apple Developer
   account portal.

`Debug.xcconfig` / `Release.xcconfig` pull it in via `#include? "Local.xcconfig"` — the
`?` makes it optional, so CI and the simulator (no signing) build without the file. The
Xcode project deliberately carries **no** `DEVELOPMENT_TEAM`, so the local value is the
only source.

---

## Publishing

All nine federated packages are publishable; only the workspace root and `example` stay
private. Siblings depend on each other by **version constraint** (`^x.y.z`), not `path:` —
the pub workspace links them locally for dev, and melos keeps the constraints in lockstep
on bump. Publish in **dependency order** (platform interface → core → impls → app-facing).

```bash
# 1. Coordinated version bump (Conventional Commits drive the bump)
melos version

# 2. Dry-run `dart pub publish --dry-run` in every non-private package — must be clean
dart run melos run publish:dry-run

# 3. Publish in dependency order
melos publish
```
