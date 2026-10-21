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
| [main.swift](../Sources/dmucode/main.swift) | App delegate, startup, loading dmucode's config. |
| [AppMenu.swift](../Sources/dmucode/AppMenu.swift), [AppConfig.swift](../Sources/dmucodeCore/AppConfig.swift) | The main menu, and the config file whose `keybind`s set its shortcuts. `AppSettings.swift` hands the config's chrome options to the views. |
| [FullDiskAccess.swift](../Sources/dmucodeCore/FullDiskAccess.swift), [FullDiskAccessPrompt.swift](../Sources/dmucode/FullDiskAccessPrompt.swift) | Whether the app has Full Disk Access, and the sheet that sends the user to System Settings for it. |
| [MainWindowController.swift](../Sources/dmucode/MainWindowController.swift) | The window: sidebar, tab bar, terminals, palette, theme and fullscreen handling. Also `TerminalContainerController`, which holds one terminal per opened session. |
| [SessionStore.swift](../Sources/dmucodeCore/SessionStore.swift) | The sidebar's model: sessions, selection, attention markers, recent sessions, the sidebar layout. Owns the control-mode client and falls back to polling. |
| [TmuxBackend.swift](../Sources/dmucodeCore/TmuxBackend.swift) | The protocols `SessionStore` is written against (see [Testing](#testing)), and the production scheduler. |
| [TmuxControlClient.swift](../Sources/dmucodeCore/TmuxControlClient.swift) | The control-mode client: process, heartbeat, logging, and `ControlModeParser` for the protocol. Its write queue and reply matching are in `ControlCommandPipeline`. |
| [ExecutableLookup.swift](../Sources/dmucodeCore/ExecutableLookup.swift) | Finding `tmux` and `git` by absolute path. |
| [Tmux.swift](../Sources/dmucodeCore/Tmux.swift) | The tmux CLI wrapper, the list formats and their parsers; `TmuxSession`, `TmuxWindow`, `TmuxPane`. `Subprocess.swift` runs the processes. |
| [Sesh.swift](../Sources/dmucodeCore/Sesh.swift) | Session templates for the palette: the `SessionTemplates` protocol and `Sesh`, which lists them with `sesh list` and starts one with `sesh connect`. |
| [SidebarView.swift](../Sources/dmucode/SidebarView.swift), [SidebarLayout.swift](../Sources/dmucodeCore/SidebarLayout.swift) | The sidebar, and its order and groups kept by session name. |
| [TabBarView.swift](../Sources/dmucode/TabBarView.swift), [GitStatus.swift](../Sources/dmucodeCore/GitStatus.swift) | The tabs and their git status. |
| [Palette.swift](../Sources/dmucode/Palette.swift) | The ⌘K palette: one field, two modes. |
| [SessionSwitcher.swift](../Sources/dmucode/SessionSwitcher.swift), [FuzzyMatch.swift](../Sources/dmucodeCore/FuzzyMatch.swift) | Session mode and its fuzzy matching. |
| [CommandBar.swift](../Sources/dmucode/CommandBar.swift) | Command mode (tmux commands), and the palette's shared look. |
| [TerminalView.swift](../Sources/dmucode/TerminalView.swift) | One libghostty surface in an `NSView`: keyboard through `interpretKeyEvents` (so dead keys and input methods work), mouse, scrolling, size. |
| [GhosttyInput.swift](../Sources/dmucode/GhosttyInput.swift) | Key translation, adapted from Ghostty's macOS app (MIT). |
| [GhosttyRuntime.swift](../Sources/dmucode/GhosttyRuntime.swift) | The process-wide `ghostty_app_t`: config loading and reloading, the theme, clipboard and libghostty's action callbacks. |
| [ConfigWatcher.swift](../Sources/dmucode/ConfigWatcher.swift) | FSEvents on the Ghostty and dmucode config directories. |
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
  - Commands are written to the client's stdin on a dedicated serial queue (`ControlCommandPipeline`), never under the lock and never on the caller's thread, so a server that stops reading can't block the main thread or the heartbeat. A command counts as overdue from the moment it is queued, so a stuck write is detected like a missing reply; a failed write fails that command's callback and the ones queued after it.
  - The tmux client hands its stdin and stdout to the server, which reads and writes them directly. So a stall happens on the server side: stopping the client process (`kill -STOP`) doesn't stall the connection, stopping the server does.
- **Logging:** everything goes to the unified log through `os.Logger` (`Log` in dmucodeCore), subsystem `com.dmuko.dmucode`, with the categories `control` (this connection), `ghostty` (config errors) and `debug` (the debug hook). Connecting, exiting and stalls are in `control`. Notifications and sent commands are logged at debug level, which isn't persisted; watch them with `log stream --level debug`.
- **Switching sessions inside tmux:** `%client-session-changed` includes the client's tty. If it is the tty of one of dmucode's terminals (`ghostty_surface_tty_name`), that terminal moves to the new session and the sidebar follows (`prefix s`, `switch-client`).
- **Paths, git status and alert flags:** a `cd` sends no notification, so the client subscribes to a format (`refresh-client -B`) that contains every window's `pane_current_path` and alert flags across all sessions. tmux checks subscriptions about once a second and sends `%subscription-changed` when the value changes.
  - The selected session's directories get `git --no-optional-locks status --porcelain=v2 --branch` as soon as they change, then every 3 seconds, since editing files sends no event.
  - **Pausing:** the 3-second timer runs only while someone can see the result. `GitStatusStore.setActive(_:)` stops it, and the window controller calls it with `false` when the app resigns active, the window is minimized, or the window is fully occluded (`NSWindow.occlusionState`), and with `true` when all of those clear. Resuming runs an update at once and restarts the timer. Directories that change while paused still get one update, so a session switched from elsewhere shows its status, but no timer starts. An update asked for while one is running (resume, new directories) runs again when it finishes.
  - The timer, the runner and the queues are injected, so the tests drive ticks and activation without waiting or running git.
- **Side effects:** the control client is an attached client as far as tmux is concerned. `tmux ls` shows one session as attached, and `client-attached` hooks run for it. The sidebar's attached count ignores control clients.

## Finding executables

Apps started from Finder don't inherit the shell's `PATH`, so `ExecutableLookup` searches by absolute path, the same way for tmux and git. The order, first executable wins:

1. `DMUCODE_TMUX` (tmux only; skipped if it isn't executable).
2. `/opt/homebrew/bin`, `/usr/local/bin` (Homebrew), `/opt/local/bin` (MacPorts).
3. Nix: `~/.nix-profile/bin`, `/etc/profiles/per-user/$USER/bin`, `/run/current-system/sw/bin`, `/nix/var/nix/profiles/default/bin`.
4. `/usr/bin`, then the absolute directories of the process's own `PATH` (set when started from a terminal).
5. For tmux, if nothing was found: the login shell, `$SHELL -l -c 'command -v tmux'` (the user's shell from the password database if `SHELL` is unset). It runs off the main thread with a 3-second timeout (the shell is terminated after that), ignores banners by taking the last output line that is an absolute executable path, and ignores aliases and functions. The shell is not interactive, so only the profile files (`.zprofile`, `config.fish`, `.bash_profile`) apply, not `.zshrc`.

The directory tmux was found in goes first in the `PATH` of every tmux process the app starts (`Tmux.environment`), followed by the other known locations and the inherited `PATH`, so a tmux server started by dmucode finds the same tools. The filesystem check is injected, so the tests use a fake filesystem.

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
- **Session templates:** with sesh installed (`Sesh.resolve`, found like tmux and git but without the login-shell fallback), the templates are fetched when the palette opens (`sesh list --config --json`), and the ones whose name isn't a running session's are matched by name and directory, after the sessions so that a session wins a tie with its own template. Choosing one runs `sesh connect <name>` (`SessionStore.startTemplate`):
  - sesh runs with `TMUX` set to the server's socket path (`Tmux.socketPath`, computed as tmux does from `-L`: `$TMUX_TMPDIR`/`tmux-<uid>`/name) and `TMUX_PANE` to the shown session's active pane. The tmux CLI takes the socket from `TMUX` when there is no `-L`, so sesh's tmux calls reach the app's server; and sesh, seeing `TMUX`, switches a client instead of attaching, which has no terminal here. The client is found from `TMUX_PANE` as for the command bar, so the terminal showing that session moves to the new one, and `%client-session-changed` makes the sidebar follow.
  - With no session shown there is no client to switch, and sesh reports a failure after creating the session. So the outcome is judged by the session list after a refresh: a session of the template's name is selected, otherwise sesh's message is shown as a command error.
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
- **Format version:** the JSON is `{"version": 2, "entries": [...], "lastSeen": {"<name>": <seconds since 2001-01-01>}}`. Version 1 was unversioned (only `entries`) and is read as is. Data with a newer `version` than the build knows isn't read: the sidebar starts from defaults in memory and `SessionStore` doesn't save the layout that run, so a newer dmucode's layout isn't overwritten after a downgrade. Unreadable data is replaced.
- **Pruning:** each successful session listing stamps the names in it in `lastSeen` (renewed only when an hour old, to avoid rewriting the defaults on every event), then `pruned(now:present:)` forgets the names not seen for 30 days. Names in the listing are never pruned. A pruned name leaves its group, and a group that loses all its sessions goes too; groups that were empty stay. Names without a stamp (version 1 data) are stamped on the first listing, so nothing is pruned right after the upgrade. A name that comes back is added as new, at the end.

## dmucode's configuration

`AppConfig` (dmucodeCore) parses `~/.config/dmucode/config` in Ghostty's `key = value` syntax; `$XDG_CONFIG_HOME` and `DMUCODE_CONFIG` are honored like Ghostty's and tmux's own overrides. A line that fails is reported as "line N: …" and skipped, and the rest applies, as libghostty does with the Ghostty config. A missing file is the defaults.

- **Keybinds:** `KeyTrigger` is modifiers plus a character or a `NamedKey`; `KeybindAction` is the menu action, with `goto_session:N` and `goto_tab:N` carrying their position. `KeybindAction.defaults` holds the shortcuts without a config, and `AppConfig.keybindings` applies the `keybind` lines to them in order: a trigger bound to an action is taken from the action that had it, and `unbind` frees it. Each action has at most one shortcut, because it is a menu item's key equivalent.
- **The menu:** `AppMenu` builds the main menu once, keeping each item by its action, and `apply` sets the key equivalents and modifier masks; a reload never rebuilds the menu. Named keys become AppKit's function-key characters (`NSUpArrowFunctionKey`…).
- **Reloading:** the app delegate loads the config at launch, on Reload Config (⇧⌘,, which reloads the Ghostty config too) and when `ConfigWatcher` sees `config` saved in the directory. The watcher is created once the directory exists, so a config directory created while the app runs is picked up after a manual reload. Errors go to the `config` log category and to the same sheet as Ghostty's config errors, kept apart per source so a fix to one doesn't hide the other's.
- **Control shortcuts:** `TerminalView.performKeyEquivalent` keeps control combinations for the terminal, so a `ctrl+…` keybind is offered to the main menu first and goes to the terminal only if no item claims it.
- **Chrome options:** the rest of the config (`title-bar`, `tabs`, `tab-git-status`, `sidebar-window-count`, `sidebar-shortcuts`) reaches the views through `AppSettings`, an `ObservableObject` the app delegate replaces the config in on each reload, so SwiftUI views observing it redraw. The window controller subscribes for the rest:
  - **Tabs:** `TerminalContainerController.tabBarVisible` hides the tab bar and gives its height to the terminals; the palette's overlay follows. `auto` is decided from the selected session's window count whenever the sessions or the config change.
  - **Git:** with `tab-git-status = false` the controller tracks no directories, so no `git status` runs.
  - **Full Disk Access:** `FullDiskAccess` (dmucodeCore) can only find out whether the process has it, by opening `TCC.db`, which also lists the app in the System Settings pane; `FullDiskAccessPrompt` (app) shows the sheet, remembers Don't Ask Again in `UserDefaults`, and opens the pane by its `x-apple.systempreferences:` URL. The window controller asks at launch after the config-error sheet, and only when no sheet is up, since a window holds one sheet at a time.
  - **Title bar:** with `title-bar = false` the window keeps `.titled`, for its frame, shadow and resizing, and its transparent title bar, but hides the title; the traffic lights stay where they are, which is the top strip of the sidebar, as in Finder. The sidebar always respects the title bar's safe area, so its content starts under them. The tab bar and the palette's hosting views get `safeAreaRegions = []` and the terminal container ignores the title bar (`ignoresTitleBar`), or they would inset their content by the title bar's height; clicks on tabs under the title bar reach them, since the title bar is transparent. With the sidebar collapsed (observed through the split view item's `isCollapsed`) the tabs would sit under the buttons, so they keep the strip then. The window becomes movable by its background. Leaving native fullscreen, where AppKit hides the buttons itself, applies it again.

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

## Concurrency

The package uses Swift 6 tooling in language mode 5, with complete concurrency checking (`StrictConcurrency`) reported as warnings, so the places where code crosses threads stay visible.

- **Threads:** UI and model state live on the main thread. The rest is serial queues, each with one job:
  - `dmucode.tmux`: tmux CLI commands from `SessionStore`.
  - The control client's reader (stdout), its write queue (`dmucode.tmux-control.write`) and its heartbeat timer.
  - `dmucode.git`: `git status` runs.
  - libghostty calls its runtime callbacks (wakeup, actions, clipboard) on its own threads. `GhosttyRuntime` and `TerminalView` hop to the main thread before touching AppKit.
  
  Results come back to the main thread with `DispatchQueue.main.async`, not with actors.
- **Warnings at the time of writing:** 111, from a clean `swift build --build-tests`:

  | Where | Warnings | Mostly |
  |---|---|---|
  | `dmucode` (the app) | 87 | AppKit types (`TerminalView`'s `NSTextInputClient` conformance, `DebugHooks`, the app delegate) used from nonisolated code: 51 in `DebugHooks`, 18 in `GhosttyRuntime`, 14 in `main.swift` |
  | `dmucodeCore` | 21 | Closures handed to `DispatchQueue` that aren't `@Sendable` (`TmuxControlClient`, `GitStatus`, `TmuxBackend`'s scheduler, `ControlCommandPipeline`) |
  | `dmucodeTests` | 3 | Blocking `wait()` inside async tests |

  By category: 64 main actor isolation, 42 Sendable, 1 global mutable state (`DebugHooks`' timer), plus the test waits.
- **Toward language mode 6:**
  - Mark the AppKit and SwiftUI side `@MainActor`: the window controller, views, `GhosttyRuntime` and the debug hook. Make protocol conformances such as `NSTextInputClient` explicitly isolated or `@preconcurrency`.
  - Make the work closures in `StoreScheduler`, the control client and `GitStatusStore` `@Sendable`, along with the values they capture.
  - Make `SessionStore` and `GitStatusStore` `@MainActor`, which they already are by convention.
  - Replace the semaphore waits in the tests with `async` waiting.
  
  Each warning fixed in mode 5 is one fewer error when switching.

## Testing

- **Unit tests** (`swift test`, Swift Testing) import `dmucodeCore` with `@testable import`, so they run on a fresh clone without building GhosttyKit. They cover:
  - `ControlModeParser`, the list and `git status` parsers, and the pane title filters
  - `FuzzyMatch` and `SidebarLayout`
  - `SessionStore`: selection and the remembered session, the restore placeholder, alerts, the error sources, the switch between polling and control mode, and starting a session template
  - `Sesh`'s list parser and error messages, `Tmux.socketPath`, and the environment sesh runs in
  - `AppConfig`: the parser and its errors, trigger spellings, action names, how `keybind` lines resolve against the defaults, and the chrome options
- **A fake tmux for `SessionStore`:** the store depends on protocols, not on `Process`. `TmuxBackend` is the tmux CLI (the real `Tmux` conforms), `TmuxControlConnection` is the control-mode client (`TmuxControlClient`), and `StoreScheduler` is where its work runs and when (queues, delays and the polling timer). The public `TmuxCommands` is the part of `TmuxBackend` that the app's `SessionStore.perform` closures get. The app creates the store with `SessionStore(tmux:)`, which wires in the real ones; tests use the internal initializer with `FakeTmux`, `FakeControl`, `FakeTemplates` (for `SessionTemplates`) and a `ManualScheduler` (in `Tests/dmucodeTests/SessionStoreFakes.swift`) that runs background work at once and moves time only when the test says so, so nothing waits. Each test gets its own `UserDefaults` suite, which is removed afterwards.
  - `ExecutableLookup` (on a fake filesystem, plus throwaway shell scripts for the login-shell fallback) and the pausing of `GitStatusStore` (with a fake timer and runner)
- **UI behavior** is checked with a test instance against its own tmux server (`DMUCODE_TMUX_SOCKET`), driven through the debug hook (`DMUCODE_DEBUG_DIR`). The hook's `state` command dumps:
  - the sidebar rows
  - the palette
  - the theme and window state
  - the focused text field's contents
