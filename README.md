<div align="center">

# Ledge

**Your MacBook's notch, put to work.**

You already look up there. Ledge puts what you're checking anyway — the song,
the timer, the next meeting — in the black bar you've been ignoring since 2021.
Quiet when nothing is happening, there the moment something is.

<a href="https://github.com/egemertbalcik/Ledge/releases/latest/download/Ledge.dmg"><img src="https://img.shields.io/badge/Download%20for%20macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download Ledge for macOS"></a>
<a href="https://buymeacoffee.com/egebalcik" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black" alt="Buy me a coffee"></a>

[ledgeapp.dev](https://ledgeapp.dev) · free · open source · no account, no telemetry

<a href="https://github.com/egemertbalcik/Ledge/releases/latest"><img src="https://img.shields.io/github/v/release/egemertbalcik/Ledge?label=release&color=0071e3" alt="Latest release"></a>
<img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26 or later">
<img src="https://img.shields.io/badge/Developer%20ID-signed%20%26%20notarized-2ea44f" alt="Signed with a Developer ID and notarized by Apple">
<a href="LICENSE"><img src="https://img.shields.io/github/license/egemertbalcik/Ledge?color=555" alt="License: GPL-3.0"></a>

<img src="docs/media/intro.gif" width="460" alt="Ledge waking up in the notch">

<!-- FILM SLOT: when the film is out, put its poster here linked to YouTube,
     e.g. [![Watch the Ledge film](docs/media/film-poster.jpg)](https://www.youtube.com/watch?v=VIDEO_ID)
     GitHub strips iframes, so a linked poster is the only way to show it. -->

</div>

**What is Ledge?** Ledge is a free, open-source (GPL-3.0) notch app for
MacBook. It turns the notch into a live status area, like the iPhone's Dynamic
Island: now playing, a timer, your next meeting with a camera mirror on the
Join button, weather, notes, Keep Awake (lid closed too), AirPods, and volume
and brightness readouts. It needs a MacBook with a notch on macOS 26 or later,
ships signed and notarized, has no account and no telemetry, and records no
audio or screen.

---

## Skip a track without losing your place

Cover art, the title, the scrub bar, the buttons. Send the sound to your AirPods
from the same card. Works with Music, with Spotify, and with whatever tab is
playing in your browser.

<img src="docs/media/media.gif" width="520" alt="The Now Playing card: transport, scrub bar and the AirPlay output list">

## Keep an eye on the timer without watching it

Start a focus session and the countdown moves to the edge of the notch. It sits
there while you work, close enough to glance at, too small to distract you.

<img src="docs/media/timer.gif" width="520" alt="The timer card, and a countdown resting beside the notch">

## Your day, one glance up

What's next, and the month it belongs to. The weather where you are, and the
hours coming. When a meeting is about to start, the Join button grows a little
mirror: one click and your camera opens in the card, so you can fix your hair
before anyone else sees it. Choose which calendars show, account by account, in
Settings.

<table>
<tr>
<td width="50%"><img src="docs/media/calendar.gif" width="100%" alt="The calendar card: the day's events beside the month grid"></td>
<td width="50%"><img src="docs/media/weather.gif" width="100%" alt="The weather card: current conditions and the hourly forecast"></td>
</tr>
</table>

## Leave it working and walk away

Running a build, a long download, or an agent that needs another hour? Keep
Awake holds the Mac and the screen on until you say stop. It's what
`caffeinate` does, minus the terminal.

Move it one stop further and the Mac keeps going with the lid shut. The screen,
the keyboard light and the speakers go quiet so the battery goes to the work,
and it all lets go at the time you set. That stop needs a small helper running
as root. It's only installed when you turn it on, and it's removed when you turn
it off. Keep Awake itself stays out of the way until you switch it on in
Settings.

## Write it down before it's gone

A phone number, a command, the thing you'll forget in ten minutes. Notes keeps
your five most recent on a card, and opens each one in its own window when
there's more to say. They're plain files on your Mac, and any of them can go
to Apple Notes in one click.

## And the rest

| | |
|---|---|
| **Volume & brightness** | A readout that replaces the grey square macOS drops in the middle of your screen. Hover it and the bar becomes a slider. |
| **AirPods & Bluetooth** | They connect, you see it — with battery, and the case animation you were promised on the iPhone. |
| **Battery** | Where it stands, and a nudge while there's still time to do something about it. |
| **Focus modes** | Tells you which mode just turned on. macOS barely mentions it. |
| **File shelf** | Drop files on the notch, pull them out later. New screenshots land there by themselves. |
| **Camera & mic** | A dot when something is recording, right where you're looking. |
| **Caps Lock & keyboard layout** | Which one is on, without hunting for a menu bar flag. |
| **Levels** | Sound and brightness as sliders on a card, for the keyboards and mice with no keys for it. |

Every one of these can be switched off on its own. A source you turn off is
never even built, so it does no work and asks for nothing.

## What it will never do

Ledge **records nothing**. No screen capture, no audio capture, nothing saved
from the camera. The camera opens only when you press the mirror, shows only
you, and closes when the card does. The equalizer that dances along with your
music never hears a note of it: it's an animation seeded from the track,
reading zero bytes of audio. There was an early
version that sampled system audio, and it was deleted for exactly this reason.
Nobody should have to trust a notch app with a microphone.

It also stays **out of your screenshots**, your recordings and the screen you
share in meetings. There's a switch for when you do want to show it off.

Four things go over the network and nothing else: the weather (Open-Meteo, with
your coordinates rounded to about a kilometre), the place name for it (Apple),
cover art from whatever is playing, and the update check. No account, nothing to
sign up for, no telemetry.

## What it reaches for

Ledge does things macOS does not offer publicly, and you should know what before
you install it.

It is **not sandboxed**, and it uses three private frameworks: `DisplayServices`
for brightness, `CoreBrightness` to dim the keyboard light while the lid is
shut, and `MediaRemote` to see what is playing in any app. Reading
MediaRemote is not permitted to ordinary apps, so Ledge loads a small library of
its own into `/usr/bin/perl` — a program Apple signs and entitles — and asks
from there. That library does one thing, exports one symbol, and reports what is
playing; nothing is written, and nothing else is touched. Every private symbol
is looked up at runtime and checked, so when Apple removes one the feature
quietly stops instead of the app crashing.

Accessibility, if you grant it, is used for one purpose: catching the volume and
brightness keys so Ledge's readout can replace the system's rather than appear
under it.

Keep Awake's lid-shut stop installs a helper that runs as root, because only root
can stop a MacBook from sleeping when the lid closes. It holds the Mac awake on a
90-second lease that Ledge keeps renewing. If Ledge crashes, is force-quit or is
updated mid-hold, the lease runs out and the Mac is free to sleep again. Nobody
has to remember to undo it.

The consequences are real: this is software that can break on any macOS update,
and it can never be sold on the App Store. The source for all of it is here.

## Install

[Download the DMG](https://github.com/egemertbalcik/Ledge/releases/latest/download/Ledge.dmg),
drag Ledge into Applications, and open it **from Finder** — macOS gives the
permissions to whatever launched the app, so starting it from a terminal hands
them to the terminal instead. After that it keeps itself up to date with
[Sparkle](https://sparkle-project.org); there's a *Check for Updates…* in
Settings, under General.

There's no Dock icon — the notch is the app. The only time Ledge shows up in the
menu bar is while it's holding the Mac awake with the lid shut, because once the
lid is down the notch is out of reach. Open Ledge again from Finder or Spotlight
and the copy that's already running brings its Settings up. Quitting is a button
in there, under General.

Not on Homebrew yet; the disk image above is the way in for now.
<!-- HOMEBREW SLOT: uncomment once egemertbalcik/homebrew-tap exists.
Or with Homebrew:

```sh
brew install --cask egemertbalcik/tap/ledge
```
-->

**You'll need** a MacBook with a notch — the 14- or 16-inch Pro from 2021, the
Air from 2022 — on macOS 26 or later. Ledge draws on that display and nowhere
else, on purpose: external monitors come in every shape, and a silhouette cut
for the notch wouldn't be the same app on them.

## Permissions

Nothing is asked for at launch. Each permission is requested by the one feature
that needs it, from the Permissions tab in Settings — and everything else carries
on without it.

| Permission | What it gives you | If you say no |
|---|---|---|
| Accessibility | Ledge's readout instead of the system one | You get both, stacked |
| Automation | Cover art and scrubbing in Music and Spotify, and sending a note to Apple Notes | Music still shows up, just without the artwork; notes stay in Ledge |
| Calendars | Your next event, and the month | No calendar card |
| Camera | The mirror on the Join button | No mirror; Join still works |
| Bluetooth | Connections the moment they happen, and AirPods proximity | Still read, just a beat later |
| Focus status | The notch says when a Focus is on, and stays quiet during it | Announcements come through regardless |
| The Focus folder *(optional, not a system permission)* | The Focus card follows the switch immediately, and names the mode | Still shown, within a few seconds, as "Focus" |
| Location | Weather for wherever you are | Weather for a city you type in |
| Login Items *(Keep Awake's helper)* | Keeping the Mac awake with the lid shut | Awake still works, lid open |

## How it compares

There are other notch apps, and some will suit you better.
[boring.notch](https://github.com/TheBoredTeam/boring.notch) is free and open
source too, and runs on macOS 14, on Intel Macs and on external displays.
[Atoll](https://github.com/Ebullioscopic/Atoll) has system stats and clipboard
history. Alcove and NotchNook are paid, polished, and work on any display.
Ledge is the one for a notched MacBook on macOS 26 if you want a signed app
that asks for nothing until a feature needs it and records nothing. A sourced
comparison, checked October 2026:
[free alternatives to Alcove and NotchNook](https://egemertbalcik.com/notes/free-alcove-notchnook-alternatives/).

## Build it yourself

```sh
git clone https://github.com/egemertbalcik/Ledge.git
cd Ledge
make run          # build, sign, launch
```

You'll need Swift 6.2 and an `Apple Development` signing identity. `make test`
runs the suite, `make lint` checks the layer boundaries.

Written from scratch, with no code from any other project.

## License

Copyright © 2026 Ege Mert Balçık. GPL-3.0 — see [LICENSE](LICENSE). Fork it,
learn from it, ship your own — as long as what you ship stays open too.

---

<div align="center">

Made by <a href="https://github.com/egemertbalcik">Ege Mert Balçık</a> · <a href="https://ledgeapp.dev">ledgeapp.dev</a><br>
If Ledge earns its place in your notch, <a href="https://buymeacoffee.com/egebalcik" target="_blank" rel="noopener noreferrer">buy me a coffee</a>.

</div>
