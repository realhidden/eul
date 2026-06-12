<p align="center">
  <img src="Resource/Assets.xcassets/AppIcon.appiconset/eul@256px.png" height=96 />
</p>

# eul 2.0

A calm system monitor for the macOS menu bar — this fork revives and redesigns [gao-sun/eul](https://github.com/gao-sun/eul) for modern macOS and Apple Silicon, rebuilt around one idea: **glanceable when things are fine, useful when they aren't.**

## Highlights

- **One entry point in the bar.** Your pinned metrics render as a single strip; when the menu bar gets crowded, a width governor collapses it slot by slot down to the eyes — eul never silently disappears.
- **An investigation panel, not a dropdown.** Click the strip for a top-down read: verdict, metric tiles with sparklines, top processes by CPU / memory / network, and eul's own footprint reported on every open.
- **A health engine instead of a Christmas tree.** Surfaces stay monochrome until a *sustained* signal trips — thermal pressure, memory pressure, disk almost full, runaway process — then exactly the responsible metric tints amber or red, in the bar and in the panel.
- **Fan control with a real safety model.** A privileged helper (macOS 13+, approved by you in System Settings) drives the fans: linked by default with one stepped slider, Auto / Manual / Boost per fan if you unlink. Targets are clamped to hardware limits, macOS can always cool past your setting, and fans revert to Auto whenever eul isn't running — enforced by the helper's own dead-man watchdog, not by good intentions.
- **Honest widgets.** Health and Trends widgets that say how old their data is instead of pretending to be live.
- **Native, cheap sampling.** Metrics come from syscalls, not shelled-out tools; container writes and widget reloads are skipped when nothing consumes them; refresh cadence (1–10 s) is one slider with its energy cost stated next to it.
- **Personalization without a layout editor.** Hide tiles you don't care about (right-click), value-only bar slots, °C/°F and MB/s ⇄ Mb/s units, 23 languages.

## OS Requirement

macOS 10.15+ (Catalina) for the app. Fan control requires macOS 13+ and a signed build. Big Sur 11+ for widgets. Universal: Apple Silicon + Intel.

## Installation

No binary releases yet on this fork — build from source:

```bash
git clone https://github.com/chrsomle/eul.git && cd eul

xcodebuild -scheme eul -project ./eul.xcodeproj -sdk macosx -configuration Release build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<your team id> -allowProvisioningUpdates
```

Copy the built `eul.app` from DerivedData into `/Applications`. A real signing team (free Apple Developer account works) is required for fan control — macOS refuses to register privileged helpers from unsigned apps. Everything else runs fine unsigned:

```bash
xcodebuild -scheme eul -project ./eul.xcodeproj -sdk macosx build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" \
  CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"
```

## Development

SwiftUI throughout, no test target — CI builds and lint-checks formatting. Run the formatter before committing:

```bash
cd BuildTools && swift run -c release swiftformat ../ --lint   # check
cd BuildTools && swift run -c release swiftformat ..           # fix
```

The design direction and component specs live in [`design/handoff`](design/handoff). The app icon is generated from code: [`design/icon/generate-appicon.swift`](design/icon/generate-appicon.swift).

## Acknowledgements

eul was created by [gao-sun](https://github.com/gao-sun) — this fork stands on that work and keeps its localization community's contributions.

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tr>
    <td align="center"><a href="https://github.com/XaoflySho"><img src="https://avatars3.githubusercontent.com/u/13835089?v=4?s=48" width="48px;" alt=""/><br /><sub><b>XaoflySho</b></sub></a><br /><a href="https://github.com/gao-sun/eul/commits?author=XaoflySho" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/akeschmidi"><img src="https://avatars1.githubusercontent.com/u/10963753?v=4?s=48" width="48px;" alt=""/><br /><sub><b>akeschmidi</b></sub></a><br /><a href="#translation-akeschmidi" title="Translation">🌍</a></td>
    <td align="center"><a href="http://artkost.ru/"><img src="https://avatars2.githubusercontent.com/u/62051?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Nikolay Kostyurin</b></sub></a><br /><a href="#translation-JiLiZART" title="Translation">🌍</a></td>
    <td align="center"><a href="http://jesusm.github.io/"><img src="https://avatars3.githubusercontent.com/u/752469?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Jesus</b></sub></a><br /><a href="#translation-JesusM" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/kant"><img src="https://avatars1.githubusercontent.com/u/32717?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Darío Hereñú</b></sub></a><br /><a href="#translation-kant" title="Translation">🌍</a></td>
    <td align="center"><a href="http://opensource.generali-cloud.net/"><img src="https://avatars2.githubusercontent.com/u/25303664?v=4?s=48" width="48px;" alt=""/><br /><sub><b>R. Fuehrer</b></sub></a><br /><a href="#translation-rfuehrer" title="Translation">🌍</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/jorgeclaro"><img src="https://avatars2.githubusercontent.com/u/10659042?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Jorge Claro</b></sub></a><br /><a href="#translation-jorgeclaro" title="Translation">🌍</a></td>
    <td align="center"><a href="https://medium.com/@zorig"><img src="https://avatars0.githubusercontent.com/u/1277672?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Zorig</b></sub></a><br /><a href="#translation-Zorig" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/lill74"><img src="https://avatars2.githubusercontent.com/u/12353597?v=4?s=48" width="48px;" alt=""/><br /><sub><b>lill74</b></sub></a><br /><a href="#translation-lill74" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/strafe"><img src="https://avatars0.githubusercontent.com/u/15663890?v=4?s=48" width="48px;" alt=""/><br /><sub><b>strafe</b></sub></a><br /><a href="#translation-strafe" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/AndyH0ng"><img src="https://avatars0.githubusercontent.com/u/60703412?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Andy Hong</b></sub></a><br /><a href="#translation-AndyH0ng" title="Translation">🌍</a></td>
    <td align="center"><a href="https://treastrain.jp/"><img src="https://avatars2.githubusercontent.com/u/13805382?v=4?s=48" width="48px;" alt=""/><br /><sub><b>treastrain / Tanaka Ryoga</b></sub></a><br /><a href="#translation-treastrain" title="Translation">🌍</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/baptistecdr"><img src="https://avatars3.githubusercontent.com/u/11665396?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Baptiste C.</b></sub></a><br /><a href="#translation-baptistecdr" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/b3z"><img src="https://avatars2.githubusercontent.com/u/47346598?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Luca</b></sub></a><br /><a href="#translation-b3z" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/40uf411"><img src="https://avatars0.githubusercontent.com/u/29804103?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Ali AOUF &#124; علي عوف</b></sub></a><br /><a href="#translation-40uf411" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/sboh1214"><img src="https://avatars0.githubusercontent.com/u/30364442?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Seungbin Oh</b></sub></a><br /><a href="#translation-sboh1214" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/nrudnyk"><img src="https://avatars.githubusercontent.com/u/20221382?v=4?s=48" width="48px;" alt=""/><br /><sub><b>nrudnyk</b></sub></a><br /><a href="#translation-nrudnyk" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/kawarimidoll"><img src="https://avatars.githubusercontent.com/u/8146876?v=4?s=48" width="48px;" alt=""/><br /><sub><b>カワリミ人形</b></sub></a><br /><a href="https://github.com/gao-sun/eul/commits?author=kawarimidoll" title="Documentation">📖</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/ivyjsgit"><img src="https://avatars.githubusercontent.com/u/34287279?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Ivy Jackson</b></sub></a><br /><a href="https://github.com/gao-sun/eul/commits?author=ivyjsgit" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/J-rg"><img src="https://avatars.githubusercontent.com/u/4042863?v=4?s=48" width="48px;" alt=""/><br /><sub><b>J-rg</b></sub></a><br /><a href="#translation-J-rg" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/jevonmao"><img src="https://avatars.githubusercontent.com/u/64660730?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Jevon Mao</b></sub></a><br /><a href="https://github.com/gao-sun/eul/commits?author=jevonmao" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/Tekrific"><img src="https://avatars.githubusercontent.com/u/68393566?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Tekrific</b></sub></a><br /><a href="#translation-Tekrific" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/nebeker"><img src="https://avatars.githubusercontent.com/u/8558191?v=4?s=48" width="48px;" alt=""/><br /><sub><b>nebeker</b></sub></a><br /><a href="#translation-nebeker" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/DMNerd"><img src="https://avatars.githubusercontent.com/u/7889445?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Adam</b></sub></a><br /><a href="#translation-DMNerd" title="Translation">🌍</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/stosumarte"><img src="https://avatars.githubusercontent.com/u/64950825?v=4?s=48" width="48px;" alt=""/><br /><sub><b>stosumarte</b></sub></a><br /><a href="#translation-stosumarte" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/gnehs"><img src="https://avatars.githubusercontent.com/u/16719720?v=4?s=48" width="48px;" alt=""/><br /><sub><b>gnehs</b></sub></a><br /><a href="#translation-gnehs" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/Animenosekai"><img src="https://avatars.githubusercontent.com/u/40539549?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Animenosekai</b></sub></a><br /><a href="#translation-Animenosekai" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/soewaiyanmyowin"><img src="https://avatars.githubusercontent.com/u/38293630?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Soe Wai Yan Myo Win</b></sub></a><br /><a href="#translation-soewaiyanmyowin" title="Translation">🌍</a></td>
    <td align="center"><a href="http://www.studio83.cz/"><img src="https://avatars.githubusercontent.com/u/9982805?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Vojtěch Kaizr</b></sub></a><br /><a href="#translation-wojtishek" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/thewqer"><img src="https://avatars.githubusercontent.com/u/64782240?v=4?s=48" width="48px;" alt=""/><br /><sub><b>wqer</b></sub></a><br /><a href="#translation-thewqer" title="Translation">🌍</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/sn0wmem0ry"><img src="https://avatars.githubusercontent.com/u/84455611?v=4?s=48" width="48px;" alt=""/><br /><sub><b>sn0wmem0ry</b></sub></a><br /><a href="#translation-sn0wmem0ry" title="Translation">🌍</a></td>
    <td align="center"><a href="https://github.com/daimajia"><img src="https://avatars.githubusercontent.com/u/2503423?v=4?s=48" width="48px;" alt=""/><br /><sub><b>代码家</b></sub></a><br /><a href="https://github.com/gao-sun/eul/commits?author=daimajia" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/bitigchi"><img src="https://avatars.githubusercontent.com/u/2769571?v=4?s=48" width="48px;" alt=""/><br /><sub><b>Emir Sarı</b></sub></a><br /><a href="#translation-bitigchi" title="Translation">🌍</a></td>
  </tr>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

## Language Support

```swift
let languages = [
  "简体中文", "English", "العربية",
  "Deutsch", "Русский", "Español",
  "Português", "Монгол", "한국어",
  "日本語", "Français", "Українська",
  "Svenska", "Čeština", "Italiano",
  "繁體中文", "မြန်မာဘာသာ", "Magyar",
  "ไทย", "Türkçe", "فارسی",
  "Polski", "Dansk",
];
```
