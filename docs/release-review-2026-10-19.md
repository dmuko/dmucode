# Pre-release review, 2026-10-19

A review of the codebase before publishing it as open source, from two angles: is it ready to publish, and are the solutions sustainable with outside contributors. Each item is a checkbox; tick them off as they are done, and delete this file once it is empty.

**State at the time of the review:** `swift build` and `swift test` pass (65 tests in 6 suites), no secrets in the history, MIT license and Ghostty attribution in place.

## Before publishing

- [x] **Error messages vanish at once.** `SessionStore.perform` sets `errorMessage` and then calls `refresh`, whose successful `apply` clears the message a few milliseconds later ([SessionStore.swift:160](../Sources/dmucodeCore/SessionStore.swift#L160), [:380](../Sources/dmucodeCore/SessionStore.swift#L380)). Renaming a session to an existing name shows nothing. The control-mode connection error at [:290](../Sources/dmucodeCore/SessionStore.swift#L290) is cleared the same way by the next poll. Keep command errors apart from listing errors, or clear the message only on the user's next action.
- [x] **Remove the pre-release migration.** `DefaultsMigration` copies settings from the bundle id `dev.dmucode.app`, which nobody else ever had. Its tests also write into the real `~/Library/Preferences`. Delete `Sources/dmucode/DefaultsMigration.swift`, `Tests/dmucodeTests/DefaultsMigrationTests.swift`, the call in `main.swift`, and the row in `docs/ARCHITECTURE.md`.
- [x] **Personal host name in tests** ([TmuxParseTests.swift:63](../Tests/dmucodeTests/TmuxParseTests.swift#L63), [:87](../Tests/dmucodeTests/TmuxParseTests.swift#L87)). Replace with a neutral one.
- [x] **Ghostty's license is missing from the app bundle.** `scripts/build-app.sh` copies Ghostty's terminfo, themes and shell integration into the app but not `vendor/ghostty/LICENSE`. MIT requires the notice to travel with the code.
- [x] **Wording.** The comments at [GhosttyRuntime.swift:199](../Sources/dmucode/GhosttyRuntime.swift#L199) and [:266](../Sources/dmucode/GhosttyRuntime.swift#L266) talk about "the prototype". Say "not handled yet" or similar.
- [x] Add `applicationSupportsSecureRestorableState` to the app delegate (macOS 14 logs a warning without it).
- [x] Add `.swiftpm/` and `.DS_Store` to `.gitignore`.
- [ ] Tag `v0.1.0` when publishing.

## Structural, for sustainability

1. [x] **Tests need GhosttyKit.** `@testable import dmucode` links the whole app target, so a fresh clone can't run `swift test` without the five-minute Zig build. Split the package into a GhosttyKit-free `dmucodeCore` target (the tmux parsers, `ControlModeParser`, `SidebarLayout`, `FuzzyMatch`, `GitStatus.parse`) and the app. This is the single most valuable change, because it makes the next item possible.
2. [ ] **No CI.** Add a GitHub Actions workflow on a macOS runner that runs the core tests on every PR. The full app build works too if GhosttyKit is cached with the submodule SHA as the key.
3. [x] **Ghostty is pinned to an arbitrary commit on main** (`431126c`, "Update VOUCHED list", 2026-10-18), as a shallow submodule. Since `ghostty.h` is unstable, record in `ARCHITECTURE.md` why this commit, and move to a release tag as soon as the needed API is in one. Make `build-ghosttykit.sh` check that the Zig version starts with `0.16` and fail with a clear message.
4. [x] **`SessionStore` can't be tested.** The most involved logic (the restore placeholder, `fixSelection`, alerts, the polling/control-mode switch) depends directly on the `Process`-based `Tmux` struct and `TmuxControlClient`, and has no tests. A protocol for the backend would allow a fake tmux.
5. [ ] **Executable paths are hard-coded.** [Tmux.swift:85](../Sources/dmucodeCore/Tmux.swift#L85) and [GitStatus.swift:59](../Sources/dmucodeCore/GitStatus.swift#L59) know only Homebrew, `/usr/local` and `/usr/bin`. MacPorts and Nix users get "tmux not found" right away. Add `/opt/local/bin` and the Nix profile paths, or resolve the path once through the login shell. Likely the first issue anyone files.
6. [ ] **Swift 6 toolchain, language mode 5.** Concurrency checking is effectively off, and the code crosses threads on purpose (libghostty callbacks, `TerminalView` userdata, `GhosttyRuntime.shared`). They are well commented; enable `StrictConcurrency` as an upcoming feature so the inventory shows up as warnings for contributors.
7. [ ] **The sidebar layout grows without bound.** Every session name ever seen stays in the `UserDefaults` JSON forever, and the stored format has no version field. Add a version and prune names not seen for, say, 30 days.
8. [ ] **Git polling every 3 seconds** for every tab directory, also while the app is inactive ([GitStatus.swift:70](../Sources/dmucodeCore/GitStatus.swift#L70)). Costs battery in large repositories. Pause the timer while the app is in the background or the window is hidden.
9. [x] **Hidden terminals live forever.** Every opened session keeps a Metal surface and a tmux client process alive. With dozens of sessions this should be capped LRU-style, or at least listed under Known limitations.
10. [ ] **The control client writes under the lock on the main thread** ([TmuxControlClient.swift:101](../Sources/dmucodeCore/TmuxControlClient.swift#L101)). If the server stalls and stops reading stdin, the main thread blocks once the pipe fills, and the heartbeat thread then waits for the same lock, so the stall detector itself stops working. Unlikely with small commands, but the write belongs on its own queue.

## Smaller

- [ ] `Tmux.run` reads stdout to the end before stderr, which can deadlock if stderr exceeds 64 KB. Doesn't happen with tmux in practice.
- [ ] `NSSound.beep()` rings on every bell regardless of Ghostty's `bell-features` setting.
- [ ] Logging mixes `NSLog` and `os.Logger`. Unify on `Logger`.
- [ ] The tmux 3.2 minimum isn't verified by anything. Say "tested with 3.8" in the README or add a matrix to CI.
- [ ] `DebugHooks` is compiled into release builds and lets anyone who can write to `DMUCODE_DEBUG_DIR` inject keystrokes. Acceptable behind the environment variable, but a conscious decision.
- [ ] Add a short `CONTRIBUTING.md`: build, tests, the dev instance with `DMUCODE_TMUX_SOCKET`, the debug hook, the branch and PR convention.

Items 3 and 10 are conclusions from reading the code; the stall scenario and a Ghostty update weren't exercised during the review.
