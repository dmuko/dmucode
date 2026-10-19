# dmucode – tmux-sessiot sivupalkissa, terminaalina libghostty

Minimaalinen macOS-prototyyppi:

- Vasemmassa sivupalkissa näkyvät tmux-palvelimen sessiot. Lista päivittyy tapahtumista tmuxin control mode -yhteyden kautta.
- Kun klikkaat sessiota, oikealle avautuu Ghostty-terminaali (GhosttyKit), jossa ajetaan `tmux attach-session -t <id>`.
- Sivupalkki merkitsee kellolla session, jossa soi bell tai joka lähetti ilmoituksen (esim. Claude Code odottaa vastausta). Ilmoituksen teksti näkyy session alla.
- Session tmux-ikkunat näkyvät tabeina terminaalin yläpuolella. Tabissa näkyy aktiivisen panen hakemisto ja, jos hakemisto on git-repossa, haara ja tila.
- Splitit ja muun hoitaa tmux itse.

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
| ⌘1…⌘9 | hyppää sessioon (sivupalkin järjestyksessä) |
| ⌘↓ / ⌘↑ | seuraava / edellinen sessio |
| ⌘R | nimeä sessio uudelleen |
| ⌃⌘S | näytä / piilota sivupalkki |
| ⌘K | sessionvaihdin: sumea haku session nimestä tai ikkunan nimestä ja hakemistosta. Tyhjällä haulla viimeksi käytetty ensin, joten ⌘K ↩ palaa edelliseen sessioon. ⌘K korvaa Ghosttyn `clear_screen`-pikanäppäimen; tmuxissa ruudun tyhjentää `clear` tai C-l. |
| ⌘: | tmux-komentopalkki (kuten `prefix :`) |
| oikea klikkaus | Rename / Move to Group / Kill |
| session raahaus | järjestä sivupalkki; raahaa ryhmän alle siirtääksesi ryhmään |
| sivupalkin kansio-painike | uusi ryhmä (ryhmän oikea klikkaus: Rename / Remove) |
| tabin klikkaus | valitse tmux-ikkuna |
| ⌘T tai tabipalkin + | uusi tmux-ikkuna nykyisen panen hakemistoon |
| ⌘W | sulje nykyinen tmux-ikkuna (kysyy ensin) |
| ⌥⌘R | nimeä nykyinen tmux-ikkuna uudelleen |
| ⌘→ / ⌘← | seuraava / edellinen tabi |
| ⌥⌘1…⌥⌘9 | hyppää tabiin (järjestysnumero vasemmalta, ei tmuxin indeksi) |
| tabin oikea klikkaus | Rename / Close Window |

Sivupalkin järjestys ja ryhmät muistetaan session nimen perusteella ([SidebarLayout.swift](Sources/dmucode/SidebarLayout.swift)). Jos sessio tapetaan ja samanniminen luodaan myöhemmin, esimerkiksi rebootin jälkeen, se palaa samaan kohtaan ja samaan ryhmään. Uusi nimi tulee ryhmättömien sessioiden loppuun. Kun sessio nimetään uudelleen, se pysyy paikallaan. Ryhmän voi raahata otsikosta, jolloin ryhmän sessiot tulevat mukana. Ryhmä asettuu aina ryhmien väliin, koska ryhmättömät sessiot ovat ylimpänä. Järjestys tallennetaan tmux-socketeittain sovelluksen asetuksiin.

Ghostty-asetukset (fontti, teema) luetaan tiedostosta `~/.config/ghostty/config`.

Claude Code -ilmoituksia varten lisää tiedostoon `~/.claude/settings.json` jokaisella koneella rivi `"preferredNotifChannel": "iterm2_with_bell"`. Silloin sivupalkin kello syttyy kaikissa sessioissa ja ikkunoissa, ja ilmoituksen teksti näkyy session alla (ks. [Control mode -yhteys](#control-mode--yhteys)).

Ympäristömuuttujat:

- `DMUCODE_TMUX_SOCKET=nimi` käyttää erillistä tmux-palvelinta (`tmux -L nimi`). Hyödyllinen testaukseen, ettei oikeisiin sessioihin kosketa.
- `DMUCODE_TMUX=/polku/tmux` ohittaa tmuxin automaattisen etsinnän.
- `DMUCODE_RESURRECT_DIR=hakemisto` vaihtaa hakemiston, josta tmux-resurrectin tallennusta etsitään (testejä varten).
- `DMUCODE_DEBUG_DIR=hakemisto` kytkee testikoukun päälle (komennot `snapshot`, `state`, `pixels`, `type`, `ctrl`, `key`, `press`, `select`, `move`, `group`, `ungroup`, `togroup`, `tab`, `newtab`, `cmdbar`, `new`). Katso [DebugHooks.swift](Sources/dmucode/DebugHooks.swift): koukulla voi ottaa ikkunasta kuvan ja syöttää näppäilyjä ilman Accessibility- tai Screen Recording -oikeuksia.

## Rakenne

- [TerminalView.swift](Sources/dmucode/TerminalView.swift): yksi Ghostty-surface NSView'ssä. Näppäimistö kulkee `interpretKeyEvents`in kautta, jotta kuolleet näppäimet ja IME toimivat. Lisäksi hiiri, vieritys ja koko.
- [GhosttyRuntime.swift](Sources/dmucode/GhosttyRuntime.swift): `ghostty_app_t`, konfiguraatio, leikepöytä ja Ghosttyn action-callbackit.
- [Tmux.swift](Sources/dmucode/Tmux.swift) ja [SessionStore.swift](Sources/dmucode/SessionStore.swift): tmux-CLI-kääre ja sivupalkin malli.
- [MainWindowController.swift](Sources/dmucode/MainWindowController.swift) ja [SidebarView.swift](Sources/dmucode/SidebarView.swift): ikkuna, sivupalkki ja terminaalinäkymien vaihto.
- [TabBarView.swift](Sources/dmucode/TabBarView.swift): valitun session tmux-ikkunat tabeina.
- [GitStatus.swift](Sources/dmucode/GitStatus.swift): tabien git-tila.
- [CommandBar.swift](Sources/dmucode/CommandBar.swift): ⌘:-komentopalkki.
- [SidebarLayout.swift](Sources/dmucode/SidebarLayout.swift): sivupalkin järjestys ja ryhmät session nimien mukaan.
- [SessionSwitcher.swift](Sources/dmucode/SessionSwitcher.swift) ja [FuzzyMatch.swift](Sources/dmucode/FuzzyMatch.swift): ⌘K-sessionvaihdin ja sen sumea haku.
- [GhosttyInput.swift](Sources/dmucode/GhosttyInput.swift): näppäinten muunnokset, sovitettu Ghosttyn macOS-sovelluksesta (MIT).
- [scripts/make-icon.swift](scripts/make-icon.swift): piirtää sovelluksen ikonin (D ja C osittain päällekkäin) CoreGraphicsilla. Käytössä on paletti `mocha`. Ikoni luodaan uudelleen komennolla `swift scripts/make-icon.swift icns mocha Resources/AppIcon.icns`, ja kaikkien palettien vertailukuva komennolla `swift scripts/make-icon.swift preview build/icon-preview.png`.

## Control mode -yhteys

Sovellus pitää yllä yhtä `tmux -C attach-session` -clientia ([TmuxControlClient.swift](Sources/dmucode/TmuxControlClient.swift)) ja kuuntelee sen ilmoituksia: `%sessions-changed`, `%session-renamed`, `%window-add`/`-close`/`-renamed`, `%unlinked-window-*`, `%session-window-changed`, `%subscription-changed`, `%client-session-changed` ja `%client-detached`. Jokainen ilmoitus käynnistää uuden kyselyn (`list-sessions` + `list-windows -a` + `list-clients`) samaa yhteyttä pitkin. Saman purskeen ilmoitukset niputetaan 50 ms:n sisällä.

- **Liputukset:** client asettaa `no-output` (panejen tuloste ei virtaa sovellukseen), `ignore-size` (ei vaikuta ikkunoiden kokoon) ja `no-detach-on-destroy` (jos sen oma sessio tapetaan, se siirtyy toiseen sessioon eikä katkea).
- **Ilman sessioita:** control-clientin on pakko liittyä johonkin sessioon. Kun palvelinta tai sessioita ei ole, sovellus pollaa CLI:tä kerran sekunnissa ja yhdistää heti, kun sessio ilmestyy. Sivupalkin otsikon vihreä pallo tarkoittaa tapahtumapohjaista tilaa, harmaa pollausta.
- **Jumiutunut yhteys:** prosessin päättyminen tai EOF ei paljasta yhteyttä, joka on jumissa mutta auki. Siksi sovellus lähettää 10 sekunnin välein no-op-komennon (`display-message -p ok`), jos mikään komento ei odota vastausta. Jos vanhin vastaus on yli 5 sekuntia myöhässä, client tapetaan ja sovellus pollaa, kunnes yhteys aukeaa uudelleen. Jumi huomataan siis 10–20 sekunnissa. tmux-client antaa stdininsä ja stdoutinsa palvelimelle, joka lukee ja kirjoittaa niitä suoraan, joten jumi syntyy palvelimen päässä: client-prosessin pysäyttäminen (`kill -STOP`) ei jumita yhteyttä, palvelimen pysäyttäminen jumittaa.
- **Loki:** yhteyden avaus, päättyminen ja jumit kirjataan järjestelmälokiin: `/usr/bin/log show --last 1h --predicate 'subsystem == "dev.dmucode.app"'`. Ilmoitukset ja lähetetyt komennot kirjataan debug-tasolla, jota ei tallenneta; ne näkee livenä komennolla `/usr/bin/log stream --level debug --predicate 'subsystem == "dev.dmucode.app"'`. Polku `/usr/bin/log` tarvitaan zsh:ssa, jossa `log` on sisäänrakennettu komento.
- **Session vaihto tmuxin sisällä:** `%client-session-changed` kertoo clientin tty:n. Jos se on jonkin terminaalin tty (`ghostty_surface_tty_name`), terminaali siirretään uuden session alle ja sivupalkki seuraa (`prefix s`, `switch-client`).
- **Tabien hakemisto ja git:** `cd` ei tuota ilmoitusta, joten client tilaa tmuxilta formaatin (`refresh-client -B`), joka sisältää jokaisen ikkunan `pane_current_path`in kaikista sessioista. tmux tarkistaa tilauksen noin kerran sekunnissa ja lähettää muutoksesta `%subscription-changed`-ilmoituksen. Valitun session hakemistoille ajetaan `git --no-optional-locks status --porcelain=v2 --branch` heti, kun hakemistot muuttuvat, ja sen jälkeen 3 sekunnin välein, koska tiedostojen muokkauksesta ei tule tapahtumaa. Tabissa näkyy haara (irrotetussa tilassa commit), oranssi pallo jos muutoksia on, punainen kolmio jos konflikteja on, ja ↑/↓ ahead/behind-luvuille. Tooltipissa on koko polku ja muutosten määrät.
- **Huomiomerkit:** merkillä on kaksi lähdettä.
  - **dmucoden omat terminaalit:** libghostty kertoo bellistä (`RING_BELL`) ja työpöytäilmoituksesta (`DESKTOP_NOTIFICATION`, OSC 9 tai OSC 777). tmux välittää session minkä tahansa ikkunan bellin sen clienteille, mutta OSC-ilmoitukset kulkevat tmuxin passthroughin kautta vain, kun pane on session nykyisessä ikkunassa. `allow-passthrough all` ei auta, koska tmux kirjoittaa passthroughin vain clienteille, jotka näyttävät panen. Merkki poistuu, kun sessio on valittuna ja dmucode on edessä. Jos käyttäjä katsoo jo sessiota, merkkiä ei tule.
  - **tmuxin liput:** `window_bell_flag` ja `window_activity_flag` (jälkimmäinen vain `monitor-activity on`:lla) tulevat samassa tilauksessa kuin polut. Ne kattavat sessiot, joille dmucodessa ei ole terminaalia, sekä muut kuin nykyiset ikkunat. tmux nollaa ne, kun ikkuna valitaan tai sessioon liitytään.
  - **Dockin ikoni** näyttää huomiota haluavien sessioiden määrän.
- **Claude Code:** oletusasetuksella (`auto`) Claude Code tunnistaa Ghosttyn tmuxin sisältä `TERM=xterm-ghostty`:stä (tmuxin `default-terminal`). Silloin se lähettää OSC 777 -ilmoituksen tmux-passthroughilla (`allow-passthrough on` tarvitaan). Tämä tavoittaa dmucoden vain, kun Claude on session nykyisessä ikkunassa ja sessio on avattu dmucodessa. Kattavampi asetus on `preferredNotifChannel: iterm2_with_bell`: se lähettää OSC 9 -ilmoituksen (teksti) ja bellin, ja bell näkyy tmuxin lipuista myös avaamattomissa sessioissa ja muissa ikkunoissa.
- **Komentopalkki (⌘:):** natiivi vastine tmuxin `prefix :` -kehotteelle. Rivin jäsentää tmux (`tmux source-file -`), ja se ajetaan ympäristömuuttujalla `TMUX_PANE` asetettuna näytetyn session aktiiviseen paneen. tmux pitää silloin sitä panea nykyisenä, joten komennot ilman `-t`:tä kohdistuvat siihen, mitä terminaali näyttää. Clientia tarvitsevat komennot (`detach-client`, `switch-client`) kohdistuvat sen session clientiin eli dmucoden terminaaliin. Palkki täydentää komentojen nimet `list-commands`:sta (Tab, ↑/↓), näyttää kirjoitettavan komennon käyttöohjeen sekä näyttää tulosteen (esim. `display -p`, `list-windows`) ja virheet. Historia säilyy (↑/↓, kun ehdotuksia ei ole). tmux ei ilmoita control modessa `:`-kehotteen avaamisesta, joten `prefix :` avaa edelleen tmuxin oman kehotteen.
- **Tabit:** tabit ovat valitun session ikkunat `list-windows -a`:sta. Tabin klikkaus ajaa `select-window -t $session:@ikkuna`, ja tabi vaihtuu heti. Kun ikkunaa vaihdetaan tmuxin sisällä (`prefix n`, `prefix 3`…), `%session-window-changed` siirtää korostuksen. Ikkunan valinta vaikuttaa kaikkiin samaan sessioon liitettyihin clienteihin, kuten tmuxissa muutenkin.
- **Sivuvaikutus:** control-client näkyy tmuxissa liitettynä clientina. `tmux ls` merkitsee yhden session "(attached)":ksi, ja tmux-konfiguraation `client-attached`-hookit ajetaan. Sivupalkin "attached"-laskuri ei laske control-clienteja.

## Säilyminen rebootin yli

Sessiot elävät tmux-palvelimessa, joten ne säilyvät, kun sovellus käynnistetään uudelleen. Rebootin yli ne säilyvät tmux-resurrectin ja tmux-continuumin avulla. tmux-konfiguraatioon (tpm) lisätään:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
```

Pluginit pitää myös asentaa: `prefix I` tai `~/.config/tmux/plugins/tpm/bin/install_plugins`. tpm ei asenna niitä itsestään. Toimivuuden voi tarkistaa näin: `prefix C-s` tallentaa, ja tiedoston `~/.local/share/tmux/resurrect/last` pitää ilmestyä.

- **Tallennus:** continuum tallentaa 15 minuutin välein ja palauttaa viimeisimmän tallennuksen, kun tmux-palvelin käynnistyy.
- **Ilman status-riviä (`set -g status off`):** continuum tallentaa vain status-rivin päivityksen yhteydessä (`#(continuum_save.sh)` `status-right`:ssä), joten ilman status-riviä automaattinen tallennus ei toimi. Palautus toimii silti. Tallennus korvataan silmukalla. Silmukka saa tmuxilta oman palvelimensa `$TMUX`:n ja sammuu palvelimen mukana, ja optio estää uuden silmukan syntymisen, kun konfiguraatio ladataan uudelleen:

  ```tmux
  if -F '#{@autosave-loop}' '' {
    set -g @autosave-loop 1
    run-shell -b 'while tmux has-session 2>/dev/null; do sleep 900; ~/.config/tmux/plugins/tmux-resurrect/scripts/save.sh quiet; done'
  }
  ```
- **dmucode käynnistää palautuksen:** jos palvelin ei ole käynnissä ja tallennus löytyy (`~/.local/share/tmux/resurrect/last` tai `~/.tmux/resurrect/last`), dmucode käynnistää palvelimen väliaikaisella sessiolla. Continuum palauttaa sessiot, ja resurrect poistaa väliaikaisen session `0`.
- **Käyttöliittymä palautuksen aikana:** sovellus näyttää tekstin "Restoring tmux sessions…" eikä näytä väliaikaista sessiota. Palautuksen jälkeen valituksi tulee viimeksi käytetty sessio. Viimeksi käytetty sessio muistetaan nimellä ja erikseen jokaiselle tmux-socketille.
- **Jos palautusta ei tule 20 sekunnissa:** väliaikainen sessio näytetään tavallisena sessiona.

## Huomioita

- **Wait-after-command:** libghostty pakottaa `wait-after-command`in päälle, kun surfacelle annetaan komento. Siksi tmux-clientin poistuminen käsitellään `SHOW_CHILD_EXITED`-actionista. Muuten jäljelle jäisi "Press any key" -ruutu.
- **TERMINFO:** jos tmux-konfiguraatiossa on `default-terminal xterm-ghostty` ja sovellus käynnistää tmux-palvelimen itse, palvelimelle annetaan `TERMINFO`, joka osoittaa bundlen terminfo-hakemistoon.

## Tunnetut rajoitukset

- **Continuumin vartija:** continuum ohittaa sekä palautuksen että automaattitallennuksen, jos se luulee toisen tmux-palvelimen olevan käynnissä. Se laskee prosessit, joiden komentorivi alkaa sanalla `tmux`. dmucode kutsuu tmuxia absoluuttisella polulla, joten sen prosessit eivät näy tässä laskussa, mutta esimerkiksi erillinen `tmux -L` -palvelin estää palautuksen.
- **Mukautettu tallennushakemisto:** `@resurrect-dir` ei ole tuettu palautuksen käynnistyksessä, koska asetusta ei voi lukea ennen kuin palvelin on käynnissä.
- **Ikkunoiden järjestys:** `swap-window` ei lähetä control mode -ilmoitusta, joten tabien järjestys päivittyy vasta seuraavan tapahtuman (esim. ikkunan vaihdon) jälkeen.
- **Puuttuvat ominaisuudet:** tabeja ei voi vielä raahata, ja bell-/activity-merkinnät puuttuvat. Myös `flagsChanged`-modifier-tapahtumat, osoitinmuodot ja asetusikkuna puuttuvat.
