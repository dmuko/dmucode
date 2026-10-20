# dmucode

**A macOS terminal for tmux: your sessions in a sidebar, each one in a native Ghostty terminal.**

![dmucode: tmux sessions grouped in the sidebar, the selected session's windows as tabs with git status, and an agent session asking for attention](docs/images/dmucode.jpg)

dmucode is a native macOS app built around a tmux server. The sidebar lists the server's sessions and updates live. The selected session runs in a terminal rendered by [libghostty](https://github.com/ghostty-org/ghostty), the engine of the Ghostty terminal, with your Ghostty fonts, theme and settings. The session's tmux windows are shown as tabs.

Sessions belong to tmux, not to the app. Quitting dmucode only detaches its clients, so your programs keep running. With tmux-resurrect, the sessions also come back after a reboot. This works well for many long-lived sessions, such as several AI coding agents side by side, where you want to see at a glance which one is waiting for you.

> **Status:** an early, personal project. It runs only on macOS, and you build it from source. It embeds libghostty through `ghostty.h`, which is Ghostty's internal API, not a stable one. Expect rough edges.

## Features

- **Live session sidebar.** dmucode keeps a tmux control-mode connection, so new, renamed and closed sessions show up immediately, without polling.
- **Ghostty terminals.** Each session gets its own libghostty surface with your `~/.config/ghostty/config`: fonts, themes, background opacity and blur. Saving the config applies it right away.
- **Windows as tabs.** Each tab shows the directory of the window's active pane and, inside a git repository, the branch and whether there are changes, conflicts or unpushed commits.
- **Attention markers.** A session whose terminal rings the bell or sends a desktop notification (OSC 9/777) gets an orange bell and the notification's text, for example when Claude Code is waiting for input. The Dock icon shows how many sessions want attention.
- **⌘K palette.**
  - Fuzzy-find any session, window or pane. Panes are found by their title too, where Claude Code writes the topic of its conversation.
  - Start the line with `:` to run a tmux command.
- **Your order, remembered.**
  - Drag sessions into any order and into groups.
  - Sessions named `group/name` file themselves under `group`.
  - The order is remembered by session name, so it survives restarts and reboots.
- **Restore after reboot.** If tmux-resurrect has a save and no tmux server is running, dmucode starts the server so that tmux-continuum restores your sessions.

![The ⌘K palette finding a Claude Code pane by the topic in its title](docs/images/palette.jpg)

## Requirements

- An Apple silicon Mac with macOS 14 or later.
- [tmux](https://github.com/tmux/tmux) 3.2 or later. 3.6 or later is recommended, and dmucode is developed with 3.8.
- To build from source: Xcode 16 or later (Swift 6), and [Zig](https://ziglang.org) **0.16.x** for libghostty. Ghostty needs this exact minor version, so Homebrew's current `zig` won't do; install `zig@0.16`.

## Installation

### Homebrew

```bash
brew install --cask dmuko/tap/dmucode
```

This installs tmux too. `brew upgrade --cask dmucode` updates the app; your sessions keep running in tmux meanwhile. Releases are signed with a Developer ID and notarized, and the DMGs are also on the [releases page](https://github.com/dmuko/dmucode/releases).

### From source

Building libghostty takes about five minutes the first time.

```bash
brew install tmux zig@0.16

git clone --recurse-submodules https://github.com/dmuko/dmucode.git
cd dmucode
./scripts/build-ghosttykit.sh   # libghostty → vendor/ghostty/macos/GhosttyKit.xcframework
./scripts/build-app.sh          # → build/dmucode.app

cp -R build/dmucode.app /Applications/
open /Applications/dmucode.app
```

`build-ghosttykit.sh` finds Homebrew's `zig@0.16` by itself; to use another Zig, set `ZIG=/path/to/zig`. The app is signed ad hoc, which is enough to run it on the machine that built it.

**Updating a source build:**

1. Run `git pull` and `git submodule update`.
2. If the `vendor/ghostty` submodule moved, run `build-ghosttykit.sh` again.
3. Run `build-app.sh`, copy the app again and relaunch. Your sessions keep running in tmux in the meantime.

## Getting started

1. **Launch dmucode.** The sidebar shows the sessions of your default tmux server. If there are none, press **⌘N** to create one; it starts in your home directory.
2. **Click a session** to attach to it. Inside the terminal it is plain tmux: your prefix key, splits and key bindings work as usual.
3. **Switch** with ⌘1…⌘9, ⌘↑ / ⌘↓, or **⌘K** and a few letters of a session, window or pane name. ⌘K then Return goes back to the previous session.
4. **Organize** the sidebar by dragging sessions. To create a group, click the folder button at the bottom of the sidebar, or create a session named `group/name`.
5. **Quit** whenever you like. Quitting only detaches, and the next launch shows the same sessions and selects the one you used last.

## Usage

### Sidebar

- **Row contents:** each row shows the session's name and its number of windows. A green dot means a terminal is attached to it: dmucode's own once you have opened the session, or one elsewhere. A gray dot means activity in a window, if you use `monitor-activity on` in tmux.
- **Live indicator:** the dot in the sidebar header is green while updates arrive live over control mode, and gray while dmucode polls because there is no session to connect to yet.
- **Context menu:** right-click a session for **Rename…**, **Move to Group** and **Kill Session…**. Right-click a group header for **Rename Group…** and **Remove Group**; removing a group keeps its sessions, ungrouped.
- **Dragging:**
  - Drag sessions to reorder them. Drop one under a group header to put it in that group, or above the first group to take it out.
  - Drag a group by its header to move it together with its sessions.
- **Remembered by name:** the order and groups are stored by session name, separately for each tmux socket.
  - A session that is killed and later created again with the same name returns to its place, for example after a reboot.
  - New names are added at the end of the ungrouped sessions, and renaming a session keeps its place.
- **Automatic groups:** a session named `group/name` files itself.
  - The first time dmucode sees it, the session goes to the end of the group `group` and is shown there as `name`. The group is created if needed, and an existing group matches regardless of case.
  - For example, `tmux new -s agents/claude-1` appears as `claude-1` under **agents**.
  - Renaming a session to a new prefix moves it to that group, and removing the prefix takes it out.
  - You can still drag such a session anywhere. Outside its group it shows its full name.

### Tabs

- **Contents:** the tabs are the tmux windows of the selected session. A tab shows the window's index and name, the directory of its active pane, and in a git repository:
  - the branch, or the commit when HEAD is detached
  - an orange dot for uncommitted changes
  - a red triangle for conflicts
  - ↑/↓ counts for commits ahead of or behind the upstream

  Hover over a tab for the full path and the counts.
- **Actions:** click a tab to select the window. The **+** button (⌘T) opens a new window in the current pane's directory. Right-click a tab for **Rename** and **Close Window**.
- **Sync with tmux:** switching windows inside tmux (`prefix n`, `prefix 3`…) moves the highlight too.

### The ⌘K palette

**Session mode (⌘K)** fuzzy-matches what you type against:

- session names
- window names and directories
- pane titles and programs. Programs such as Claude Code or nvim write their title into the pane; titles that are just the host name or a directory are skipped, and so are plain shells.

Return switches to the match: the session, and the window and pane when one of those matched. With an empty query, the sessions are listed by when you last used them, so ⌘K then Return toggles between the last two.

**Command mode (`:` or ⌘:)** turns the palette into tmux's command prompt. Type `:` as the first character, or open it directly with **⌘:**.

- **Completion and help:** command names complete with Tab and ↑/↓, and the usage of the command you are typing is shown below the field.
- **Results:** output (for example `display -p '#{pane_id}'` or `list-windows`) and errors appear in the palette. A command without output closes it.
- **Target:** commands run as the active pane of the shown session, so commands without `-t` act on what you see.
- **History:** ↑/↓ recall earlier commands when no completions are shown.
- **Leaving:** ⌫ on an empty command line goes back to session search.

tmux's own `prefix :` still opens tmux's prompt inside the terminal.

### Attention markers

A session that wants attention gets an orange bell in the sidebar. This happens when:

- a bell rang in one of its windows, or
- a program in it sent a desktop notification (OSC 9 or OSC 777). The notification's text is shown under the session's name.

Showing the session clears the marker. Nothing is marked for the session you are looking at. The Dock icon shows the number of sessions that want attention.

For Claude Code, see [Claude Code notifications](#claude-code-notifications).

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New session |
| ⌘R | Rename the selected session |
| ⌘1 … ⌘9 | Go to the session at that position in the sidebar |
| ⌘↓ / ⌘↑ | Next / previous session |
| ⌘K | Palette: find a session, window or pane |
| ⌘: | Palette in command mode (tmux command) |
| ⌘T | New tmux window (tab) in the current pane's directory |
| ⌘W | Close the current tmux window (asks first) |
| ⌥⌘R | Rename the current tmux window |
| ⌘→ / ⌘← | Next / previous tab |
| ⌥⌘1 … ⌥⌘9 | Go to the tab at that position (counted from the left, not tmux's index) |
| ⌃⌘S | Show / hide the sidebar |
| ⌃⌘F | Native full screen |
| ⇧⌘, | Reload the Ghostty config |
| ⌘C / ⌘V | Copy / paste |

⌘K replaces Ghostty's default `clear_screen` binding. In tmux, `clear` or `C-l` clears the pane.

## Configuration

### Ghostty

dmucode reads the Ghostty config the way Ghostty does: `~/.config/ghostty/config` (or `config.ghostty`, or under `$XDG_CONFIG_HOME/ghostty`), then `~/Library/Application Support/com.mitchellh.ghostty/config`. Fonts, colors, `theme`, `background-opacity` and `background-blur` apply to the terminals. The sidebar, tab bar and title bar take the theme's background color, and the window's light or dark appearance follows it.

The config reloads without restarting in three ways:

- **Saving it:** changes to `config`, `config.ghostty` or a file under `themes/` in those directories apply right away. Files pulled in with `config-file` from elsewhere aren't watched.
- **⇧⌘,** (*dmucode → Reload Ghostty Config*).
- **Ghostty's own `reload_config` keybinding.**

Lines with errors are skipped and the rest applies, as in Ghostty, and a sheet lists the skipped lines. In native full screen the window and sidebar are opaque, as in Ghostty.

### tmux

dmucode works with your existing tmux configuration. A few settings make it work better:

```tmux
# Lets notifications (OSC 9/777) from programs in tmux reach dmucode.
set -g allow-passthrough on

# Optional: a dot in the sidebar and on tabs for windows with new output.
setw -g monitor-activity on

# Optional: dmucode shows windows as tabs, so tmux's status line can go.
# (Read the note on tmux-continuum below before turning it off.)
set -g status off
```

If your config sets `default-terminal "xterm-ghostty"` and dmucode starts the tmux server, the server gets a `TERMINFO` that points into the app bundle, so the terminfo entry is found.

### Restoring sessions after a reboot

Install [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum), for example with [tpm](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
```

tpm doesn't install plugins by itself: press `prefix I`, or run `~/.config/tmux/plugins/tpm/bin/install_plugins`. To check that saving works, press `prefix C-s`; the file `~/.local/share/tmux/resurrect/last` should appear.

- **Saving:** continuum saves every 15 minutes and restores the latest save when the tmux server starts.
- **Restoring at launch:** if dmucode launches when no tmux server is running and a save exists, it starts the server so that continuum restores the sessions. Meanwhile it shows "Restoring tmux sessions…", and afterwards it selects the session you used last.
- **Without a status line:** continuum only saves when the status line redraws, so with `set -g status off` it never saves. Restoring still works. Replace the automatic saving with a loop that stops with the server and isn't started twice when the config is reloaded:

  ```tmux
  if -F '#{@autosave-loop}' '' {
    set -g @autosave-loop 1
    run-shell -b 'while tmux has-session 2>/dev/null; do sleep 900; ~/.config/tmux/plugins/tmux-resurrect/scripts/save.sh quiet; done'
  }
  ```

### Claude Code notifications

To get the attention marker with Claude Code's message in every session and window, add this to `~/.claude/settings.json` on each machine:

```json
"preferredNotifChannel": "iterm2_with_bell"
```

Claude Code then sends its message (OSC 9) and a bell. By default (`auto`) it sends only OSC 777 through tmux passthrough, and tmux delivers that only from the session's current window, to clients that show it. The bell is also recorded by tmux, so it reaches dmucode from any window and any session. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#attention-markers) has the details.

### Environment variables

| Variable | Effect |
|---|---|
| `DMUCODE_TMUX_SOCKET=name` | Use a separate tmux server (`tmux -L name`), e.g. to try things without touching your sessions. |
| `DMUCODE_TMUX=/path/to/tmux` | Use this tmux instead of looking in `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`. |
| `DMUCODE_RESURRECT_DIR=dir` | Look for the tmux-resurrect save here (for tests). |
| `DMUCODE_DEBUG_DIR=dir` | Enable the debug hook (see [Development](#development)). |

## Troubleshooting

- **The sidebar stops updating.** Check the dot in the sidebar header: green means a live connection. dmucode notices a stalled connection within about 20 seconds and reconnects. The connection's events are in the system log:

  ```bash
  /usr/bin/log show --last 1h --predicate 'subsystem == "com.dmuko.dmucode"'
  ```

  Use `/usr/bin/log` in zsh, where `log` is a builtin. Use `stream --level debug` instead of `show --last 1h` to watch every tmux notification live.
- **"tmux not found".** Apps started from Finder don't get your shell's `PATH`. Install tmux with Homebrew or set `DMUCODE_TMUX`.
- **No attention marker from Claude Code.** Set `allow-passthrough on` in tmux and `preferredNotifChannel` as above.
- **Sessions aren't restored after a reboot.**
  - Check that both plugins are installed and that `~/.local/share/tmux/resurrect/last` exists.
  - continuum skips restoring when it thinks another tmux server is running, for example a `tmux -L` server started at login.
- **⌘K doesn't clear the screen any more.** It opens the palette; use `clear` or `C-l` in tmux.
- **`prefix :` opens tmux's prompt, not the palette.** tmux doesn't tell control-mode clients that its prompt opened. Use ⌘: for the palette.

## Known limitations

- **Unstable Ghostty API:** libghostty's embedding API (`ghostty.h`) is internal and changes without notice. The submodule is pinned to a tested Ghostty commit.
- **Fixed tmux-resurrect directory:** a custom `@resurrect-dir` isn't supported for restoring at launch, because it can't be read before the server runs.
- **Tab order:** `swap-window` sends no control-mode notification, so the tab order updates only after the next event.
- **Missing features:** tabs can't be dragged, there is no settings window, and modifier-only key events (`flagsChanged`) and mouse pointer shapes aren't passed to the terminal yet.
- **Opened sessions stay attached:** a session you have opened keeps its terminal (a Metal surface and a `tmux attach` process) until it ends or dmucode quits, so switching back is instant. With dozens of opened sessions this adds up. There's deliberately no cap: the hidden terminal is what receives a session's notifications (OSC 9/777, e.g. Claude Code's text), so closing it would drop those for exactly the sessions you aren't looking at. Bells still reach the sidebar through tmux.
- **Shared tmux state:** dmucode's control client counts as an attached client in tmux (`tmux ls` shows a session as attached), and your `client-attached` hooks run for it.

## Development

```bash
swift build             # debug build (the app bundle comes from scripts/build-app.sh)
swift test              # unit tests (Swift Testing)
```

- **Tests:** the unit tests cover the parsers (tmux control mode, tmux list output, `git status`), the palette's fuzzy matching, and the sidebar layout. They import the app target with `@testable import dmucode`, so they need GhosttyKit like the build does.
- **Trying changes safely:** run a second instance against its own tmux server, so your real sessions aren't touched:

  ```bash
  tmux -L dev -f /dev/null new-session -d
  DMUCODE_TMUX_SOCKET=dev build/dmucode.app/Contents/MacOS/dmucode
  ```

  `-f /dev/null` keeps your tmux config out of the test server: with tmux-continuum's `@continuum-restore on`, it would restore your real sessions into it, programs included.

- **Debug hook:** with `DMUCODE_DEBUG_DIR=dir`, the app runs commands written to `dir/cmd`. It can take snapshots of the window, type keys, run menu shortcuts, drive the palette and dump its state, all without Accessibility or Screen Recording permissions. The commands are listed in [DebugHooks.swift](Sources/dmucode/DebugHooks.swift).
- **Updating Ghostty:** move the `vendor/ghostty` submodule, run `build-ghosttykit.sh` and test, since `ghostty.h` may have changed.
- **App icon:** [scripts/make-icon.swift](scripts/make-icon.swift) draws it. `swift scripts/make-icon.swift icns mocha Resources/AppIcon.icns` writes the icon, and `swift scripts/make-icon.swift preview build/icon-preview.png` writes a comparison of all palettes.

### Releasing

A release for direct distribution (outside the App Store) is signed with a Developer ID and notarized:

```bash
# once: store notarization credentials in the keychain (app-specific password from appleid.apple.com)
xcrun notarytool store-credentials dmucode --apple-id <apple id> --team-id <team id>
./scripts/release.sh    # writes build/release/dmucode-<version>.dmg
```

- **What it does:** [release.sh](scripts/release.sh) builds the app with `build-app.sh` and signs it with the Developer ID Application certificate, using the hardened runtime, a secure timestamp and [the entitlements](Resources/dmucode.entitlements). It notarizes the app and staples its ticket, then makes a DMG (the app and a link to Applications), signs, notarizes and staples that, and checks both with `spctl`. If Apple rejects a submission, it prints Apple's log.
- **Resuming:** an unchanged app that was notarized before, e.g. by a run that failed at the DMG, just gets its ticket stapled.
- **Keychain:** notarytool reads its credentials from the login keychain, so a run fails while the Mac is locked. The first submissions of a new Developer ID team can take hours.
- **Entitlements and usage descriptions:** the same as Ghostty's app. Programs running in the terminal (camera, microphone, AppleScript…) ask for these in dmucode's name, and the hardened runtime blocks them without the entitlements.
- **Version:** bump `CFBundleShortVersionString` and `CFBundleVersion` in [Info.plist](Resources/Info.plist) before a release.
- **Publishing:** tag the release commit (`git tag -a v<version>`), push the tag, and attach the DMG with `gh release create v<version> build/release/dmucode-<version>.dmg --verify-tag`. Then update `version` and `sha256` (`shasum -a 256` of the DMG) in `Casks/dmucode.rb` in [dmuko/homebrew-tap](https://github.com/dmuko/homebrew-tap), and check it with `brew audit --cask --online --strict dmuko/tap/dmucode`.
- **Architecture:** Apple silicon only, as GhosttyKit is built for arm64. Users install tmux themselves.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) describes how dmucode works: the source layout, the control-mode connection, attention markers, the palette's command mode, restoring at launch and the libghostty details.

## Acknowledgements

- [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors renders every terminal (MIT license). [GhosttyInput.swift](Sources/dmucode/GhosttyInput.swift) is adapted from Ghostty's macOS app.
- [tmux](https://github.com/tmux/tmux), whose control mode makes the live sidebar possible.
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) for surviving reboots.

## License

dmucode is released under the [MIT License](LICENSE).

Ghostty, included as a submodule in `vendor/ghostty`, and the code adapted from it in [GhosttyInput.swift](Sources/dmucode/GhosttyInput.swift) are MIT licensed by Mitchell Hashimoto and the Ghostty contributors; their notice is kept in that file and in [Ghostty's LICENSE](https://github.com/ghostty-org/ghostty/blob/main/LICENSE).
