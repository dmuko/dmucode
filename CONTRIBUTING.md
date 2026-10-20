# Contributing to dmucode

Thanks for helping. This page covers what you need for a pull request; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the app works.

## Build and test

```bash
swift test                     # unit tests; needs no GhosttyKit
./scripts/build-ghosttykit.sh  # once, ~5 min: libghostty (needs Zig 0.16.x, `brew install zig@0.16`)
./scripts/build-app.sh         # → build/dmucode.app
```

- **Tests:** `swift test` builds only the `dmucodeCore` target, so it works on a fresh clone without the Ghostty submodule. This is also what CI runs on every pull request.
- **App changes:** the app target and `build-app.sh` need GhosttyKit, built from the `vendor/ghostty` submodule (`git submodule update --init`).
- **Concurrency warnings:** the build reports complete concurrency checking as warnings. Don't add new ones; fixing existing ones is welcome (see "Concurrency" in ARCHITECTURE.md).

## Trying a change without touching your sessions

Run a second instance against its own tmux server, with an empty tmux config:

```bash
tmux -L dev -f /dev/null new-session -d
DMUCODE_TMUX_SOCKET=dev build/dmucode.app/Contents/MacOS/dmucode
```

`-f /dev/null` matters if you use tmux-continuum: with `@continuum-restore on`, your config would restore your real sessions, and the programs in them, into the test server.

To check UI behavior from a script, set `DMUCODE_DEBUG_DIR=dir` as well. The app then runs commands written to `dir/cmd`: snapshots of the window, typing keys, menu shortcuts and dumping its state with `state`. The commands are listed in [DebugHooks.swift](Sources/dmucode/DebugHooks.swift).

## Pull requests

- **One topic per pull request**, on a branch named after its kind: `feat/…`, `fix/…`, `docs/…`, `chore/…`, `test/…`.
- **Commits:** an imperative subject line ("Add …", "Fix …") and a body that says why, wrapped at about 72 columns.
- **Tests:** add or update tests for logic in `dmucodeCore`. For UI changes, say in the pull request how you checked them (for example a debug-hook snapshot).
- **Docs:** update README.md or ARCHITECTURE.md when behavior or structure changes.
- **CI:** it must pass.

By contributing you agree that your work is released under the [MIT License](LICENSE).
