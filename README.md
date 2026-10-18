# dmucode – tmux-sessiot sivupalkissa, terminaalina libghostty

Minimaalinen macOS-prototyyppi:

- Vasemmassa sivupalkissa näkyvät tmux-palvelimen sessiot. Lista päivittyy tapahtumista tmuxin control mode -yhteyden kautta.
- Kun klikkaat sessiota, oikealle avautuu Ghostty-terminaali (GhosttyKit), jossa ajetaan `tmux attach-session -t <id>`.
- Splitit, ikkunat ja muun hoitaa tmux itse.

Sessiot elävät tmux-palvelimessa, eivät sovelluksessa. Sovelluksen sulkeminen vain irrottaa tmux-clientit. Kun sovellus käynnistetään uudestaan, sivupalkki näyttää sessiot taas ja liittyy viimeksi käytettyyn.

## Rakentaminen

Tarvitaan Xcode, tmux ja Zig **0.16.x** (`brew install zig@0.16`). Ghostty vaatii tarkan minor-version, joten Homebrew'n tavallinen `zig` (0.17) ei käy. Skripti löytää `zig@0.16`:n itse, tai polun voi antaa muuttujalla `ZIG=`.

```bash
git clone --recurse-submodules https://github.com/dmuko/dmucode.git
cd dmucode
./scripts/build-ghosttykit.sh   # ~5 min, tuottaa GhosttyKit.xcframeworkin
./scripts/build-app.sh          # tuottaa build/dmucode.app
open build/dmucode.app
```

Ghostty on submoduulina hakemistossa `vendor/ghostty`, lukittuna commitiin `431126c` (2026-10-18), jolla prototyyppi on testattu. `ghostty.h` on Ghosttyn sisäinen API ja voi muuttua milloin tahansa. Kun päivität Ghosttyn, aja `build-ghosttykit.sh` uudelleen ja testaa.

## Käyttö

| | |
|---|---|
| ⌘N | uusi sessio |
| ⌘1…⌘9 | hyppää sessioon |
| ⌘⇧] / ⌘⇧[ | seuraava / edellinen sessio |
| ⌘R | nimeä sessio uudelleen |
| ⌃⌘S | näytä / piilota sivupalkki |
| oikea klikkaus | Rename / Kill |

Ghostty-asetukset (fontti, teema) luetaan tiedostosta `~/.config/ghostty/config`.

Ympäristömuuttujat:

- `DMUCODE_TMUX_SOCKET=nimi` käyttää erillistä tmux-palvelinta (`tmux -L nimi`). Hyödyllinen testaukseen, ettei oikeisiin sessioihin kosketa.
- `DMUCODE_TMUX=/polku/tmux` ohittaa tmuxin automaattisen etsinnän.
- `DMUCODE_DEBUG_DIR=hakemisto` kytkee testikoukun päälle (komennot `snapshot`, `state`, `type`, `ctrl`, `select`, `new`). Katso [DebugHooks.swift](Sources/dmucode/DebugHooks.swift): koukulla voi ottaa ikkunasta kuvan ja syöttää näppäilyjä ilman Accessibility- tai Screen Recording -oikeuksia.

## Rakenne

- [TerminalView.swift](Sources/dmucode/TerminalView.swift): yksi Ghostty-surface NSView'ssä. Näppäimistö kulkee `interpretKeyEvents`in kautta, jotta kuolleet näppäimet ja IME toimivat. Lisäksi hiiri, vieritys ja koko.
- [GhosttyRuntime.swift](Sources/dmucode/GhosttyRuntime.swift): `ghostty_app_t`, konfiguraatio, leikepöytä ja Ghosttyn action-callbackit.
- [Tmux.swift](Sources/dmucode/Tmux.swift) ja [SessionStore.swift](Sources/dmucode/SessionStore.swift): tmux-CLI-kääre ja sivupalkin malli.
- [MainWindowController.swift](Sources/dmucode/MainWindowController.swift) ja [SidebarView.swift](Sources/dmucode/SidebarView.swift): ikkuna, sivupalkki ja terminaalinäkymien vaihto.
- [GhosttyInput.swift](Sources/dmucode/GhosttyInput.swift): näppäinten muunnokset, sovitettu Ghosttyn macOS-sovelluksesta (MIT).
- [scripts/make-icon.swift](scripts/make-icon.swift): piirtää sovelluksen ikonin (D ja C osittain päällekkäin) CoreGraphicsilla. Käytössä on paletti `mocha`. Ikoni luodaan uudelleen komennolla `swift scripts/make-icon.swift icns mocha Resources/AppIcon.icns`, ja kaikkien palettien vertailukuva komennolla `swift scripts/make-icon.swift preview build/icon-preview.png`.

## Control mode -yhteys

Sovellus pitää yllä yhtä `tmux -C attach-session` -clientia ([TmuxControlClient.swift](Sources/dmucode/TmuxControlClient.swift)) ja kuuntelee sen ilmoituksia: `%sessions-changed`, `%session-renamed`, `%window-add`/`-close`, `%unlinked-window-*`, `%client-session-changed` ja `%client-detached`. Jokainen ilmoitus käynnistää uuden kyselyn (`list-sessions` + `list-clients`) samaa yhteyttä pitkin. Saman purskeen ilmoitukset niputetaan 50 ms:n sisällä.

- **Liputukset:** client asettaa `no-output` (panejen tuloste ei virtaa sovellukseen), `ignore-size` (ei vaikuta ikkunoiden kokoon) ja `no-detach-on-destroy` (jos sen oma sessio tapetaan, se siirtyy toiseen sessioon eikä katkea).
- **Ilman sessioita:** control-clientin on pakko liittyä johonkin sessioon. Kun palvelinta tai sessioita ei ole, sovellus pollaa CLI:tä kerran sekunnissa ja yhdistää heti, kun sessio ilmestyy. Sivupalkin otsikon vihreä pallo tarkoittaa tapahtumapohjaista tilaa, harmaa pollausta.
- **Session vaihto tmuxin sisällä:** `%client-session-changed` kertoo clientin tty:n. Jos se on jonkin terminaalin tty (`ghostty_surface_tty_name`), terminaali siirretään uuden session alle ja sivupalkki seuraa (`prefix s`, `switch-client`).
- **Sivuvaikutus:** control-client näkyy tmuxissa liitettynä clientina. `tmux ls` merkitsee yhden session "(attached)":ksi, ja tmux-konfiguraation `client-attached`-hookit ajetaan. Sivupalkin "attached"-laskuri ei laske control-clienteja.

## Huomioita

- **Wait-after-command:** libghostty pakottaa `wait-after-command`in päälle, kun surfacelle annetaan komento. Siksi tmux-clientin poistuminen käsitellään `SHOW_CHILD_EXITED`-actionista. Muuten jäljelle jäisi "Press any key" -ruutu.
- **TERMINFO:** jos tmux-konfiguraatiossa on `default-terminal xterm-ghostty` ja sovellus käynnistää tmux-palvelimen itse, palvelimelle annetaan `TERMINFO`, joka osoittaa bundlen terminfo-hakemistoon.

## Tunnetut rajoitukset

- **Rebootti:** rebootin yli säilyminen vaatii tmux-resurrectin ja -continuumin. Sovellus ei tee sille mitään erityistä.
- **Puuttuvat ominaisuudet:** tabit (tmuxin ikkunat) puuttuvat vielä, samoin `flagsChanged`-modifier-tapahtumat, osoitinmuodot ja asetusikkuna.
