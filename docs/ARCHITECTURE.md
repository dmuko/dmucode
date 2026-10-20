# How dmucode works

This document is for contributors and the curious. For installing and using dmucode, see the [README](../README.md).

## Overview

dmucode is an AppKit app with SwiftUI views, built with Swift Package Manager. It talks to tmux in two ways:

- **A control-mode client** (`tmux -C attach-session`), kept open for the app's lifetime. It delivers tmux's notifications (sessions and windows added, renamed, closed…) and answers queries such as the session list.
- **The tmux CLI**, for one-off commands such as creating, renaming or killing sessions and selecting windows. These run off the main thread.

Each session the user opens gets a libghostty terminal surface that runs `tmux attach-session -t <id>`. That makes it an ordinary tmux client, and tmux does everything inside it: splits, copy mode, key bindings. The surface stays alive while hidden, so switching sessions is instant.

## Source layout

The package has two targets. `dmucodeCore` (library) holds everything that doesn't need libghostty: the tmux wrapper and parsers, the session store, the sidebar layout, fuzzy matching and the git status. It imports only Foundation, so it builds, and its tests run, without GhosttyKit. `dmucode` (executable) is the app: AppKit and SwiftUI views, libghostty and the debug hook. It imports `dmucodeCore`, whose API is `public` only where the app uses it.

`Package.swift` leaves the app and the GhosttyKit binary target out while `vendor/ghostty/macos/GhosttyKit.xcframework` doesn't exist, because SwiftPM rejects a missing binary target even when nothing being built uses it.

| File | Role |
|---|---|
| [main.swift](../Sources/dmucode/main.swift) | App delegate, menus, startup. |
| [MainWindowController.swift](../Sources/dmucode/MainWindowController.swift) | The window: sidebar, tab bar, terminals, palette, theme and fullscreen handling. Also `TerminalContainerController`, which holds one terminal per opened session. |
| [SessionStore.swift](../Sources/dmucodeCore/SessionStore.swift) | The sidebar's model: sessions, selection, attention markers, recent sessions, the sidebar layout. Owns the control-mode client and falls back to polling. |
| [TmuxBackend.swift](../Sources/dmucodeCore/TmuxBackend.swift) | The protocols `SessionStore` is written against (see [Testing](#testing)), and the production scheduler. |
| [TmuxControlClient.swift](../Sources/dmucodeCore/TmuxControlClient.swift) | The control-mode client: process, heartbeat, logging, and `ControlModeParser` for the protocol. |
| [Tmux.swift](../Sources/dmucodeCore/Tmux.swift) | The tmux CLI wrapper, the list formats and their parsers; `TmuxSession`, `TmuxWindow`, `TmuxPane`. |
| [SidebarView.swift](../Sources/dmucode/SidebarView.swift), [SidebarLayout.swift](../Sources/dmucodeCore/SidebarLayout.swift) | The sidebar, and its order and groups kept by session name. |
| [TabBarView.swift](../Sources/dmucode/TabBarView.swift), [GitStatus.swift](../Sources/dmucodeCore/GitStatus.swift) | The tabs and their git status. |
| [Palette.swift](../Sources/dmucode/Palette.swift) | The ⌘K palette: one field, two modes. |
| [SessionSwitcher.swift](../Sources/dmucode/SessionSwitcher.swift), [FuzzyMatch.swift](../Sources/dmucodeCore/FuzzyMatch.swift) | Session mode and its fuzzy matching. |
| [CommandBar.swift](../Sources/dmucode/CommandBar.swift) | Command mode (tmux commands), and the palette's shared look. |
| [TerminalView.swift](../Sources/dmucode/TerminalView.swift) | One libghostty surface in an `NSView`: keyboard through `interpretKeyEvents` (so dead keys and input methods work), mouse, scrolling, size. |
| [GhosttyInput.swift](../Sources/dmucode/GhosttyInput.swift) | Key translation, adapted from Ghostty's macOS app (MIT). |
| [GhosttyRuntime.swift](../Sources/dmucode/GhosttyRuntime.swift) | The process-wide `ghostty_app_t`: config loading and reloading, the theme, clipboard and libghostty's action callbacks. |
| [ConfigWatcher.swift](../Sources/dmucode/ConfigWatcher.swift) | FSEvents on the Ghostty config directories. |
| [DebugHooks.swift](../Sources/dmucode/DebugHooks.swift) | The test harness enabled by `DMUCODE_DEBUG_DIR`. |

## The control-mode connection

dmucode keeps one control client and listens for `%sessions-changed`, `%session-renamed`, `%session-changed`, `%window-add`/`-close`/`-renamed`, `%unlinked-window-*`, `%session-window-changed`, `%subscription-changed`, `%client-session-changed` and `%client-detached`.

- **Refreshing:** each of these notifications triggers a fresh query over the same connection (`list-sessions` + `list-windows -a` + `list-clients`). Notifications that arrive within 50 ms of each other are coalesced into one query.
- **Client flags:** the client sets `no-output` (pane output doesn't stream to the app), `ignore-size` (it doesn't affect window sizes) and `no-detach-on-destroy` (if its own session is killed, it moves to another one instead of exiting). Each flag is sent as a separate command, so an older tmux that lacks one still accepts the others.
- **No sessions:** a control client has to attach to some session. While there is no server or no session, dmucode polls the CLI once a second and connects as soon as a session appears. The sidebar header's dot is green while events arrive live and gray while polling.
- **Stalls:** a connection that stalls without closing produces no exit and no EOF, so dmucode sends a heartbeat.
  - Every 10 seconds, if no command is waiting for a reply, it sends a no-op (`display-message -p ok`).
  - If the oldest pending reply is more than 5 seconds late, the client is killed, and dmucode polls until it can reconnect. A stall is therefore noticed within 10–20 seconds.
  - The timing uses `SuspendingClock`, so time asleep doesn't count.
  - The tmux client hands its stdin and stdout to the server, which reads and writes them directly. So a stall happens on the server side: stopping the client process (`kill -STOP`) doesn't stall the connection, stopping the server does.
- **Logging:** connecting, exiting and stalls go to the unified log (subsystem `com.dmuko.dmucode`, category `control`). Notifications and sent commands are logged at debug level, which isn't persisted; watch them with `log stream --level debug`.
- **Switching sessions inside tmux:** `%client-session-changed` includes the client's tty. If it is the tty of one of dmucode's terminals (`ghostty_surface_tty_name`), that terminal moves to the new session and the sidebar follows (`prefix s`, `switch-client`).
- **Paths, git status and alert flags:** a `cd` sends no notification, so the client subscribes to a format (`refresh-client -B`) that contains every window's `pane_current_path` and alert flags across all sessions. tmux checks subscriptions about once a second and sends `%subscription-changed` when the value changes.
  - The selected session's directories get `git --no-optional-locks status --porcelain=v2 --branch` as soon as they change, then every 3 seconds, since editing files sends no event.
- **Side effects:** the control client is an attached client as far as tmux is concerned. `tmux ls` shows one session as attached, and `client-attached` hooks run for it. The sidebar's attached count ignores control clients.

## Tabs

Tabs are the selected session's windows from `list-windows -a`. Clicking a tab runs `select-window -t $session:@window` and moves the highlight at once; `%session-window-changed` confirms it. Switching windows inside tmux (`prefix n`, `prefix 3`…) moves the highlight the same way. As usual in tmux, selecting a window affects every client attached to that session.

## Attention markers

A marker has two sources.

- **dmucode's own terminals:**
  - **Signals:** libghostty reports a bell (`RING_BELL`) and a desktop notification (`DESKTOP_NOTIFICATION`, from OSC 9 or OSC 777).
  - **Bells:** tmux forwards a bell from any window of a session to its clients.
  - **Notifications:** OSC notifications only pass through tmux's passthrough while the pane is in the session's current window. `allow-passthrough all` doesn't help, because tmux writes passthrough only to clients that show the pane.
  - **Clearing:** the marker clears when the session is shown while dmucode is in front, and none is raised for the session being looked at.
- **tmux's flags:** `window_bell_flag` and `window_activity_flag` come in the same subscription as the paths. The activity flag needs `monitor-activity on`. They cover sessions dmucode has no terminal for, and windows that aren't current. tmux clears them when the window is selected or the session attached.

**Claude Code:**

- **Default (`auto`):** Claude Code recognizes Ghostty inside tmux from `TERM=xterm-ghostty` (tmux's `default-terminal`) and sends OSC 777 through tmux passthrough, which needs `allow-passthrough on`. That reaches dmucode only while Claude is in the session's current window, and only for sessions opened in dmucode.
- **`preferredNotifChannel: iterm2_with_bell`:** sends OSC 9 (with the text) and a bell. The bell also shows up in tmux's flags, from any window and any session.

## The palette

- **One field, two modes:** `PaletteModel` routes the field's text to `SessionSwitcherModel` (session mode) or `CommandBarModel` (command mode).
- **The `:` sits outside the field:** it is drawn before the field, not kept in its text. NSTextField selects all its text after Return and when it gains focus, and typing over a selected `:` would drop out of command mode.
- **Switching modes:** typing `:` into an empty search switches modes on the next turn of the run loop. A SwiftUI text field doesn't show a value that its own edit's setter changes, but it does follow a change made afterwards.
- **Pane search:** panes are fetched (`list-panes -a`) each time the palette opens, since titles change without an event.
  - A title is searched only if it says more than tmux's default (the host name, flagged by the format itself), a directory (as fish sets it) or the program's name.
  - Shells aren't searched by program name.
- **Command mode:** tmux parses the line (`tmux source-file -`), which runs with `TMUX_PANE` set to the shown session's active pane. tmux then treats that pane as current, so commands without `-t` act on what the terminal shows. Commands that need a client (`detach-client`, `switch-client`) target that session's client, which is dmucode's terminal.
  - Command names complete from `list-commands`.
  - tmux doesn't tell control clients when its own `:` prompt opens, so `prefix :` can't be redirected to the palette.

## Sidebar layout

`SidebarLayout` is a flat list of group headers and session names. The sessions after a header form its group, and the ones before the first header are ungrouped. This maps directly onto one SwiftUI `ForEach` with `onMove`, since `onMove` can't move rows between `ForEach`es.

- **Absent sessions:** names of sessions that aren't running stay in the list, so the running ones keep their relative places.
- **Moving rows:** a dragged session is inserted before the row it was dropped on. A dragged group moves with its sessions, to the next boundary between groups, because ungrouped sessions must stay first.
- **Renames:** they are followed from `%session-renamed`. tmux reuses session ids after a server restart, so a changed name for an id isn't proof of a rename.
- **Automatic groups:** `group/name` sessions are filed when a name is first seen and when a rename changes the prefix, matching existing groups regardless of case.
- **Storage:** the layout is stored as JSON in the user defaults, per tmux socket (`sidebarLayout-<socket>`).

## Ghostty configuration

- **Loading:** `GhosttyRuntime` loads the default config files at launch.
- **Reloading:** a reload (a file save from `ConfigWatcher`, ⇧⌘,, or Ghostty's `reload_config` action) loads them again and calls `ghostty_app_update_config`.
  - That updates every surface, then reports the applied config through `GHOSTTY_ACTION_CONFIG_CHANGE`.
  - dmucode clones that config and reads the chrome's colors from it, so conditional settings such as `theme = light:…,dark:…` are resolved.
  - Config errors are published; libghostty skips the bad lines.
- **Chrome:** the chrome is drawn from `ChromeTheme`. That is the config's theme, made opaque in native fullscreen. Behind a fullscreen window there is only the Space's gray background, which the sidebar's behind-window material would otherwise show through its translucency. The terminals keep their own opacity, on a backdrop of the same color.

## Restoring at launch

- **Starting the restore:** if there is no tmux server and tmux-resurrect has a save (`~/.local/share/tmux/resurrect/last` or `~/.tmux/resurrect/last`), dmucode starts the server with a placeholder session. continuum then restores the sessions, and resurrect removes the placeholder session `0`.
- **Meanwhile:** the app shows "Restoring tmux sessions…" and hides the placeholder.
- **Afterwards:** the last-used session is selected. It is remembered by name, per tmux socket.
- **Timeout:** if nothing is restored within 20 seconds, the placeholder is shown as an ordinary session.
- **continuum's guard:** continuum skips restoring and automatic saving when it thinks another tmux server is running. It counts processes whose command line starts with `tmux`. dmucode runs tmux by absolute path, so its own processes don't count, but a separate `tmux -L` server does.

## libghostty notes

- **Exited clients:** libghostty forces `wait-after-command` on for surfaces given a command. When the tmux client exits (detach, session killed), dmucode closes the view on `SHOW_CHILD_EXITED`; otherwise a "Press any key" screen would stay.
- **Terminfo:** if the tmux config sets `default-terminal xterm-ghostty` and dmucode starts the server, the server gets a `TERMINFO` pointing to the app bundle's terminfo directory.
- **Pinned version:** Ghostty is a submodule in `vendor/ghostty`, pinned to a commit the app is tested with. See [The Ghostty pin](#the-ghostty-pin).

## The Ghostty pin

- **What:** `vendor/ghostty` is a shallow submodule pinned to `431126c` ("Update VOUCHED list", 2026-10-18), a commit on Ghostty's `main` branch. It is not a release tag.
- **Why not a release tag:** checked on 2026-10-20 against the latest tag, `v1.3.1` (2026-03-13). GitHub's releases list for the repository contains only the rolling `tip` release (`releases/latest` returns 404), so the tags are the only releases.
  - **Zig:** `v1.3.1` requires Zig 0.15.2 (`minimum_zig_version` in `build.zig.zon`). The pin requires 0.16.0, which is what `build-ghosttykit.sh` expects. Ghostty accepts only one Zig minor version (`requireZig`), so a Zig 0.16 toolchain can't build the tag.
  - **API:** `v1.3.1`'s `ghostty.h` lacks what dmucode uses: `ghostty_surface_tty_name` (the terminal's tty, which names its tmux client; `TerminalView` uses it to follow `%client-session-changed`), `ghostty_surface_deny_clipboard_request`, and the `ghostty_clipboard_complete_s`, `ghostty_clipboard_confirm_s` and `ghostty_clipboard_read_result_e` types. The clipboard callbacks also have different signatures there: `read_clipboard_cb` returns `bool` instead of a read result, and `ghostty_surface_complete_clipboard_request` takes a string and a flag instead of a struct. `GhosttyRuntime` is written against the newer shape.
  - **Everything else** dmucode uses (the other `ghostty_*` calls, `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`, `RING_BELL`, `SHOW_CHILD_EXITED` and so on) is present in both.
  - **Not verified:** why this particular `main` commit. It was most likely the head of `main` when the project was set up (it is dated the day before the review), and nothing is known to depend on it beyond the API above.
- **Moving the pin:**
  1. Diff `include/ghostty.h` between the old and new commit, and check each `ghostty_` call and `GHOSTTY_` constant in `Sources/dmucode` against it. A changed signature is a compile error; a changed behavior is not.
  2. Check `minimum_zig_version` in `build.zig.zon`. If the Zig minor version changes, update the check in `scripts/build-ghosttykit.sh`, the comment at its top and the README.
  3. Rebuild with `scripts/build-ghosttykit.sh`, then `swift build`.
  4. Run the app: terminals render, typing, mouse and IME work, copy and paste (including the paste confirmation), the bell and desktop notifications show attention markers, and a detached tmux client closes its view.
- **Goal:** move to a release tag as soon as one has the API above and builds with the Zig version we use. Until then, the build script refuses a Zig that isn't 0.16.x, so a mismatch fails early with a clear message instead of deep inside the Ghostty build.

## Testing

- **Unit tests** (`swift test`, Swift Testing) import `dmucodeCore` with `@testable import`, so they run on a fresh clone without building GhosttyKit. They cover:
  - `ControlModeParser`, the list and `git status` parsers, and the pane title filters
  - `FuzzyMatch` and `SidebarLayout`
  - `SessionStore`: selection and the remembered session, the restore placeholder, alerts, the error sources, and the switch between polling and control mode
- **A fake tmux for `SessionStore`:** the store depends on protocols, not on `Process`. `TmuxBackend` is the tmux CLI (the real `Tmux` conforms), `TmuxControlConnection` is the control-mode client (`TmuxControlClient`), and `StoreScheduler` is where its work runs and when (queues, delays and the polling timer). The public `TmuxCommands` is the part of `TmuxBackend` that the app's `SessionStore.perform` closures get. The app creates the store with `SessionStore(tmux:)`, which wires in the real ones; tests use the internal initializer with `FakeTmux`, `FakeControl` and a `ManualScheduler` (in `Tests/dmucodeTests/SessionStoreFakes.swift`) that runs background work at once and moves time only when the test says so, so nothing waits. Each test gets its own `UserDefaults` suite, which is removed afterwards.
- **UI behavior** is checked with a test instance against its own tmux server (`DMUCODE_TMUX_SOCKET`), driven through the debug hook (`DMUCODE_DEBUG_DIR`). The hook's `state` command dumps:
  - the sidebar rows
  - the palette
  - the theme and window state
  - the focused text field's contents
