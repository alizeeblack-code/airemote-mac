<div align="center">

<img src="icon/AppIcon.icns" width="120" alt="JoyCoding">

# JoyCoding

**Turn a game controller — or your phone — into a coding remote for macOS.**

[中文](README.zh-CN.md) · English

</div>

---

Talk to your AI coding agent instead of typing. Approve, interrupt, scroll and
switch sessions from a Joy-Con in one hand, while the other stays on the mouse.
Or leave the controller in a drawer and use your phone.

<div align="center">
<img src="docs/images/mapping.png" width="760" alt="Mapping screen">
</div>

## Why

Working with an agent is mostly a loop of **read → say something → approve → interrupt**.
None of that needs a keyboard. JoyCoding maps that loop onto a controller:

- **Hold a trigger and speak** — push-to-talk into any dictation tool
- **One button to send**, one to interrupt, one to scroll
- **The same button means the right thing in every app** — `Y` is backspace in
  your editor and *back* in Chrome, because a browser has no text to delete

## Features

- Works with **any HID gamepad** — Joy-Con (L/R), Switch Pro, PlayStation, and more
- **Per-app layers**: a base mapping plus overrides for individual apps
- **Tap / double-tap / long-press** on every button
- **Push-to-talk** that can synthesize a bare modifier key (e.g. hold left Control)
- **Phone remote** over your LAN — pair once with a 6-digit code
- **Battery level** for Nintendo controllers (macOS does not expose this; see [docs](docs/battery.md))
- Live button highlighting while you map, so you never guess a button number
- Ships with sensible defaults — plug in a controller and it just works

## Supported controllers

| Controller | Buttons | Notes |
|---|---|---|
| Joy-Con (L) / (R) | 11 | Stick direction must be learned once — it rotates 90° depending on grip |
| Switch Pro | 13 | macOS claims the Home button for its game overlay |
| PlayStation | 14–15 | Artwork and defaults ready; button numbering unverified |
| Any other HID gamepad | — | Mapping works; no illustration |

## Install

**Download** the notarized build from [Releases](../../releases) — unzip, drag to
Applications, open.

**Or build it yourself** (needs Xcode command line tools):

```bash
git clone https://github.com/YOURNAME/joycoding.git
cd joycoding && ./build.sh --no-notarize
```

## Getting started

1. Open JoyCoding. Grant **Accessibility** in System Settings when asked, then
   hit **Restart JoyCoding** in the app — macOS does not apply the grant to a
   running process.
2. Pair a controller over Bluetooth. Default mappings are applied automatically.
3. For a Joy-Con, run **Learn stick directions** once, holding it the way you
   normally do.

## Phone remote

<div align="center">
<img src="docs/images/pair.png" width="230" alt="Pairing">
&nbsp;&nbsp;&nbsp;
<img src="docs/images/remote.png" width="230" alt="Remote">
</div>

Open **Settings → Phone Remote**, scan the QR code or type the 6-digit code once.
The URL is just `http://<your-mac>:27123/` — the real token lives in a cookie
afterwards. Add it to your Home Screen and it runs full screen.

The four corners are direct app switches with real app icons; the function row
changes with whatever app is in front.

> ⚠️ This endpoint can synthesize keystrokes. Use it on a trusted LAN or
> Tailscale only — never port-forward it.

## How it works

```mermaid
flowchart LR
  C[Controller<br/>IOHIDManager] --> A
  P[Phone<br/>HTTP :27123] --> A
  A[Action table<br/>+ per-app layers] --> K[CGEvent<br/>keys / scroll / modifiers]
  K --> M[Frontmost app]
```

One action table serves both inputs, so adding an action makes it available to
the controller and the phone at once. Which keystroke an action sends is decided
at the moment you press it, based on what app is in front.

## Known limits

- **Home / PS button** is captured by macOS for its game overlay. Nothing an app
  can do short of seizing the device exclusively, which would break games.
- **Joy-Con stick direction** must be learned — the HID hat switch is defined for
  sideways play, so holding it upright rotates every direction by 90°.
- **Mac App Store is not an option.** The app needs Accessibility and raw HID
  access; the sandbox forbids both.
- Web-based apps expose nothing to the Accessibility API, so "focus the input
  box" is a positional click, not a real focus call.

## Credits

This project stands on work by others:

- **[JoyType](https://github.com/0xDarcyJ/JoyType)** — its comments pointed out
  the two things that made battery reading work: the output report must be
  padded to 49 bytes, and the report ID has to stay in byte 0 of the buffer even
  though `IOHIDDeviceSetReport` takes it separately. Without that I had written
  the feature off as impossible.
- **Linux kernel `hid-nintendo.c`** — button bit order of the `0x30` full input report.
- **[JoyKeyMapper](https://github.com/magicien/JoyKeyMapper)** and
  **[JoyConSwift](https://github.com/magicien/JoyConSwift)** by magicien — where
  this idea started.
- **[Hammerspoon](https://www.hammerspoon.org)** — the entire thing ran as a
  Lua prototype there first.
- **Apple TV Remote** and **Google TV Remote** — design reference for the phone UI.

## License

MIT — see [LICENSE](LICENSE).

Nintendo, Switch, Joy-Con and PlayStation are trademarks of their respective
owners. This project is not affiliated with, endorsed by, or connected to any of
them.
