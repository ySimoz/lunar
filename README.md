# Lunar

Native macOS spaced-repetition and STEM study application built with SwiftUI (`LunarApp`) and a local Go + SQLite core (`core`).

## Layout

- `core/` — Go daemon (`lunar-core`) managing SQLite persistence, SM-2 scheduling, import/export, and study analytics.
- `LunarApp/` — SwiftUI macOS 14+ application, offline KaTeX math rendering, CAS/2D Grapher, Pomodoro timer, and XCTest/Swift Testing suite.
- `scripts/` — Build helpers separating local debug builds from shippable release bundles.

## Tests

```bash
cd core && go test ./...
cd ../LunarApp && swift test
```

## Debug vs Release Builds

- **Debug (local / agent testing):** builds unstripped binaries into `build/debug/Lunar Debug.app` (`com.lunar.macos.debug`) and stores its SQLite database separately under `~/Library/Application Support/Lunar-Debug/lunar.db` (override with `LUNAR_DB_PATH`).

  ```bash
  ./scripts/build_debug.sh
  open "build/debug/Lunar Debug.app"
  ```

- **Release (shippable / CI):** builds stripped Go + Swift release binaries into `build/release/Lunar.app` (`com.lunar.macos`) using the production database under `~/Library/Application Support/Lunar/lunar.db`. Pass `APP_VERSION`, `CODESIGN_IDENTITY`, and `--zip` for remote/CI releases.

  ```bash
  ./scripts/build_release.sh --zip
  open build/release/Lunar.app
  ```
