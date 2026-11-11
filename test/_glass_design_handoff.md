# Hiddify home redesign: handoff

A design round is in progress on the Hiddify app's home screen (Flutter, repo `hiddify-app`, branch
`chore/flutter-3.47`, Flutter 3.47.9). Nothing of it is committed. This note says how the work is
done, where it lives, how to render it, and what is decided.

## How the work is done

- **Designs are rendered, not built in the app.** Each design is drawn from the app's real widgets
  inside a widget test (`flutter_test`) and saved as a PNG, or as frames that ffmpeg turns into an
  MP4. No device, emulator or core is needed; Riverpod overrides stand in for the core.
- **Rounds of options.** Show a few options side by side, labelled; the user picks one; the next
  round builds on the pick and changes only what the user commented on.
- **The user reads pictures, not text.** Send an image or a video for every change. Keep replies very
  short. Label options with short English names inside the image.
- **Renders:** dark theme only, English text, on home's own background (the world map), never on
  coloured blobs. Images unless a video is asked for; videos when something moves.
- **The app is not changed until home is final.** Design code lives in temp tests; the few hooks the
  tests need in `lib/` are marked `TEMP design test` and are off by default.
- **Git:** commit only when the user says so, one change per commit, Conventional Commits
  (`feat(home): …`). Never push without being asked; push only to `origin` (the user's fork).
  Never do anything risky in git.

## Where things are

- `test/_speed_ideas_test.dart`: almost all of the current design (TEMP). Key parts:
  - `_SunHome`: the whole home as designed now (profile card, connect button, status, ping, proxy
    card, glass bar). `_Sun` wraps the connect button and places the speed test and the chain
    controls around it.
  - `_UnderSun`: the status text and the bare ping under the button.
  - `_ChainItem` / `_chainItems()`: Extra security and Unblocker on the button's clock face; the
    one that is on flies to the button's top-left as its badge.
  - `_GlassShape`: the app's glass (`GlassSurface`) cut to any path; used for the glass speed icon
    (`_materialSpeed`) and the glass shield (`_shieldPath`).
  - `_GlassProfile`: the real `ProfileTile` on glass.
  - Many older design rounds (P2/P10 pills, button styles, icons, layouts) are still in the file.
- Other temp tests: `test/_connect_button_ideas_test.dart`, `test/_speed_drop_test.dart`,
  `test/_glass_*_test.dart`, `test/_nav_bar_*`, `test/features/proxy/tmp_page_design_test.dart`.
- `lib/core/widget/glass_surface.dart` + `assets/shaders/`: the glass widget (a FakeGlass port).
- TEMP hooks in `lib/` (all off by default):
  - `EclipseButtonPainter` statics (`lib/features/home/widget/eclipse_button_painter.dart`):
    `glassFace`, `glassStyle`, `hideLabel`, `hideBadge`, `hideLogo`, `debugNow` (a steady clock for
    videos), `debugFace` (what lies on the glass face), `debugLogo` (the logo's colour per tile).
  - `debugActiveProxyRowHeight` in `active_proxy_card.dart` (the main proxy row's height).
  - `ActiveProxyFooter(hideSpeedTest:, speedInCorner:)`.
  - The `_GlassTest` strip in `home_page.dart`.
- Real (not temp) app changes made during the round, uncommitted:
  - `connection_button.dart`: "not responding", "Connection failed" and "Couldn't connect" no longer
    draw the traffic light or the error animation; the button stays still in its colour (amber,
    amber, red).
  - `chain_mode_icon.dart`: the Unblocker door, when off, is half open (45°) with the dots waiting in
    front; its lines are 2.3 thick.

## How to render

Run from the repo root (not from inside a frames folder: the test deletes and recreates it).

```bash
OUT=build/glass_design flutter test test/_speed_ideas_test.dart --plain-name "home tops"
```

- `home tops` draws one full home. Knobs (environment variables): `TOP=0` (today's profile card on
  glass), `NAME=file` (output name), `MAP=.02` (map strength), `ROW=60` (main proxy row height),
  `PINGBARE=0|1`, `SPEEDRIGHT=0|1`, `FACE=.88` (white face opacity), `GLASSLOGO=1`.
- `chain badges video`: the badge animation, frames in `build/glass_design/chain_frames`.
- `sun video`: every connection state, frames in `build/glass_design/sun_frames`. `FRAMES=10,200`
  saves only those frames for a quick look.
- `twenty buttons` (`SET=sun` for the bright set), `white face glass levels` (`RING=1`,
  `LEVELS=40,50,…`), `glass hi logo`: button-only comparison sheets.

Frames to MP4 (a silent track, or the chat shows it as a GIF):

```bash
ffmpeg -y -framerate 30 -i build/glass_design/chain_frames/f_%04d.png -f lavfi -i anullsrc=r=44100:cl=stereo -shortest -c:v libx264 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:a aac build/glass_design/home_chain.mp4
```

Side by side: `ffmpeg -i a.png -i b.png -filter_complex "[0]crop=iw:ih-66:0:66[a];[1]crop=iw:ih-66:0:66[b];[a][b]hstack" out.png`
(the crop drops the label row).

## Gotchas

- A static flag read during build is the same for every tile in one image. For per-tile settings,
  pass them down with an `InheritedWidget` (see `_FaceScope`) and read them in a context hook.
- Glass (a backdrop filter) under a fade (`Opacity`/`FadeTransition`) disappears until the fade ends:
  animate size, not opacity, around glass.
- `SizeTransition` along one axis fills the other; pass `fixedCrossAxisSizeFactor: 1`.
- A `BoxDecoration` with a transparent `color` and a `gradient` draws nothing: leave `color` null.
- The connect button's animations run on a real `Stopwatch`; for videos set
  `EclipseButtonPainter.debugNow` to the test's clock.
- Fonts: the tests load the app's fonts and Windows' Segoe UI (`_load`).

## Decided so far

- Background: the world map at 2 %.
- Connect button: today's white button with its painted Hi logo; the face 20 % glass toward the rim,
  solid white under the logo. No ripple ring on connect. No chain badge until it is redesigned.
- Speed test: a glass speedometer (the Material speed icon cut from glass, faint), 22 px, at 3
  o'clock; after a test the result shows under it as L8 (upload large, download small and raised,
  Mbps under it); back to the icon 10 s after a result.
- Extra security at 8:30, Unblocker at 9:30 (the half-open door). Turning one on flies it along an
  arc to the button's top-left edge as a badge: the shield bare and green, the door orange on a plain
  dark disc. Both stay still (no animation), only their colour changes.
- Under the button: the status text ("Tap to connect", "Connected", …; "Couldn't connect" over "Tap
  to try again" in red), then the ping with no background (wifi icon + ms). "Not responding": an
  amber crossed-out wifi, then a green "Switch to fastest" glass pill with a swap icon.
- Profile card: today's card on glass, no border; the app name and version hidden for now.
- Proxy card: on glass; the main proxy row 60 px high; it grows in and out so the button glides.
- Bar: round "+", the Home/Settings capsule, round quick-settings button, all glass.

## Open

- The intro sheet that teaches Extra security before its settings (short animation, short text,
  "Don't show again"), opened from the shield.
- The PM still has to confirm the speed-test result layout and the 9/10 vs 3 placement.
- When home is final: build it into the app, remove the TEMP hooks and the temp tests, verify on
  Android and a desktop, and record before/after videos as `AGENTS.md` asks.
