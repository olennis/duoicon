# DuoIcon

<p align="center">
  <img src="Assets/favicon-source.svg" width="160" alt="DuoIcon icon">
</p>

A macOS menu bar app that shows battery, Wi-Fi, and volume status in a single icon.

## Features

- Top arc shows the battery level
- The arc turns red at 10% battery or below
- A green dot appears at the right end of the arc while the power adapter is connected
- The macOS Wi-Fi symbol sits in the center, changes across 3 levels with signal strength, and shows a slash when disconnected
- Four dots at the bottom show the volume in 25% steps, and all turn off when muted
- Pressing a volume key shows a volume control box right below the app icon
- Shortcuts to the Battery, Wi-Fi, and Sound panes of System Settings
- The menu shows the name of the connected Wi-Fi network (requires the macOS Location Services permission)

## Status display

| Area | State | How it is shown |
| --- | --- | --- |
| Top arc | Battery | Fills from the left in proportion to the charge level |
| Top arc | 10% or below | Red |
| Right end of the arc | Power connected | Green dot |
| Center | Wi-Fi connected | `wifi` system symbol, 1–3 levels by signal strength (outer arcs are dimmed at weaker levels) |
| Center | Wi-Fi disconnected | `wifi.slash` system symbol |
| Center | Volume changed | Speaker system symbol for 2 seconds |
| Center | Battery drops to 10% or below | Red battery symbol for 3 seconds |
| Bottom dots | Volume | 0–4 dots, in 25% steps |

The center symbol cross-fades over 180 ms. The animation is skipped when macOS **Reduce Motion** is enabled. Wi-Fi signal strength is based on RSSI: level 3 at -60 dBm or above, level 2 at -72 dBm or above, and level 1 below that, with a 3 dB margin so it does not flicker at the boundaries. A Wi-Fi disconnection is only reflected once it has lasted at least 1 second, to avoid flicker from transient lookup failures.

## Volume key HUD

Pressing the volume or mute keys shows a custom volume box below the DuoIcon icon instead of the default macOS HUD.

- Normal step: `1/16`
- `Option + Shift` step: `1/64`
- `Option + volume key`: keeps the macOS shortcut that opens Sound settings
- Closes automatically 2.5 seconds after the last interaction
- Stays open while the pointer is over it or the slider is being dragged
- Fades in over 180 ms and out over 140 ms

The Accessibility permission is required to intercept the volume keys and keep the default macOS HUD from appearing alongside it.

1. Launch the app.
2. Go to **System Settings → Privacy & Security → Accessibility**.
3. Allow **DuoIcon**.

Without the permission, or when the current output device does not support software volume control, the volume keys keep their default macOS behavior. With ad-hoc development signing, you may have to grant the permission again after rebuilding the app.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon or Intel Mac
- Xcode Command Line Tools or Xcode, when building from source

## Build and run

```bash
git clone https://github.com/olennis/duoicon.git
cd duoicon
sh build-app.sh
open "dist/DuoIcon.app"
```

The app runs only in the menu bar, with no Dock icon. To quit, choose **Quit DuoIcon** from the menu.

`build-app.sh` builds the release binary and the app icon, then signs the app locally with an ad-hoc signature. Distributing it to other users requires Apple Developer ID signing and notarization.

## Testing

```bash
swift run DuoIcon --self-test
```

It checks the following:

- Volume 25% boundary values
- Battery low-power and charging colors
- Center notification duration and priority
- Interruptible symbol transitions and Reduce Motion
- Wi-Fi signal strength levels and the boundary margin (3 dB)
- Wi-Fi status stabilization
- Volume HUD position and rendering

The rendered results are written to `/tmp/duoicon-icons.png` and `/tmp/duoicon-volume-hud.png`.

## Icon resources

<p align="center">
  <img src="Assets/favicon.png" width="64" alt="DuoIcon favicon">
</p>

- `Assets/icon-source.png`: source image for the macOS app icon
- `Assets/AppIcon.icns`: the macOS icon included in the app bundle
- `Assets/favicon-source.svg`: square favicon source with equal left and right margins
- `Assets/favicon.png`: 32×32 PNG favicon on a white background
- `Assets/favicon.ico`: 32×32 ICO favicon on a white background

To regenerate the favicons, build the release executable and then run:

```bash
sh build-icons.sh
```

Running `build-app.sh` also regenerates the favicons automatically.

## Project structure

```text
duoicon/
├── Assets/                  # App icon and favicon sources/outputs
├── Sources/DuoIcon/
│   ├── main.swift           # Status readers, menu, dynamic menu bar icon
│   └── VolumeKeyHUD.swift   # Volume key detection and the HUD below the icon
├── Info.plist
├── Package.swift
├── build-app.sh
└── build-icons.sh
```

## Known limitations

- The Wi-Fi status reflects whether the Mac is connected to a network, not whether the internet is reachable.
- The connected Wi-Fi name is shown only if you allow the macOS Location Services permission. Without it, the menu shows just `Connected`, and the permission is requested the first time you open the menu. DuoIcon never looks up location coordinates.
- Some external audio devices do not expose a system volume property, so the volume may show as 0% or the slider may be disabled.
- On a Mac without a battery, the battery arc is shown as inactive.

## License

Until a separate license is added, all rights are reserved by the repository owner.

## Interface language

The app follows your Mac’s preferred language and supports English and Korean. Other languages fall back to English. You can also choose a language for this app in **System Settings → General → Language & Region → Applications**. Relaunch the app after changing its language.

To verify the localization resources and language selection after a release build:

```sh
python3 scripts/check-localization.py
```
