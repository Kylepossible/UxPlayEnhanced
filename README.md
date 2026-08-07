# UxPlayEnhanced

**A lightweight, audio-only, Bonjour-free UxPlay distribution for Windows.**

UxPlayEnhanced turns a Windows PC into an AirPlay audio receiver without
installing Apple's Bonjour service. It is built on the official
[FDH2/UxPlay](https://github.com/FDH2/UxPlay) project and keeps UxPlay's audio
engine while making the packaged Windows experience intentionally audio-first:
no local video renderer, no always-open terminal, and no external mDNS service.

> Upstream: [FDH2/UxPlay](https://github.com/FDH2/UxPlay). The upstream source
> is tracked directly in this repository as the `lib/uxplay` Git submodule.
> UxPlayEnhanced is an independent Windows packaging and integration project,
> not an official FDH2 release.

## What UxPlayEnhanced Changes

| Area | UxPlayEnhanced behavior |
|---|---|
| Primary use | AirPlay audio playback on Windows |
| Video pipeline | Disabled by default with `-vs 0` |
| Device discovery | Embedded mDNS; Apple Bonjour is not required |
| User interface | Background tray application with status, song, quality, and logs |
| Installation | Self-elevating setup creates firewall rules and shortcuts |
| Audio information | Logs codec, lossless/lossy classification, and receiver format |
| Console noise | Suppresses repeated unchanged metadata blocks |

“Lightweight” refers to runtime behavior: the normal launcher does not create a
video decode/render pipeline and does not require a separate Bonjour service.
The release still includes the GStreamer and FFmpeg libraries required by
UxPlay's audio stack.

## Install

1. Download the latest Windows ZIP from the
   [UxPlayEnhanced releases](https://github.com/Kylepossible/UxPlayEnhanced/releases).
2. Extract the complete ZIP.
3. Run `UxPlayEnhanced-Setup.cmd`.
4. Approve the Windows administrator prompt.
5. Launch **UxPlayEnhanced** from the desktop or Start menu.
6. Open the AirPlay output selector on the iPhone, iPad, or Mac and choose the
   Windows computer's name.

The setup installs to `C:\Program Files\UxPlayEnhanced`, unblocks files that
inherited Windows' downloaded-file marker, creates and verifies program-scoped
inbound TCP and UDP firewall rules used by AirPlay, adds desktop and Start-menu
shortcuts, and registers an uninstall entry in Windows Apps and Features.

### Portable Use

Installation is optional. Extract the ZIP and run `setup-firewall.ps1` once; it
requests administrator access automatically. Then launch `UxPlayEnhanced.bat`.
The portable launcher also starts in audio-only mode and uses the tray
application when available.

## Tray Application

The bundled `UxPlayEnhanced.exe` runs UxPlay without an open terminal window.
Right-click its blue tray icon to see:

- AirPlay host, connected client device, and connection status
- Current artist, song, and album metadata
- Clean codec, lossless/lossy quality, bit depth, sample rate, and channels
- View logs and open the installation folder
- Restart and quit controls

Logs are stored at
`%LOCALAPPDATA%\UxPlayEnhanced\Logs\UxPlayEnhanced.log`. **View logs** opens
that file directly in Notepad, without relying on a Windows `.log` file
association.

Normal logs omit the once-per-second track progress display. Launch
`UxPlayEnhanced.exe --verbose` when troubleshooting to include those progress
updates; connection, format, metadata, warning, and error events are always
logged.

The executable bundles its Python runtime and tray dependencies. End users do
not need Python, `pip`, `pystray`, or Pillow installed.

## Audio-Only Behavior

All included launchers pass `-vs 0`, which disables UxPlay's local video sink.
This avoids local video decoding, rendering, and video-timing work while keeping
AirPlay audio reception active. The underlying `uxplay.exe` remains available
for advanced users, but screen mirroring is outside this distribution's normal
supported workflow. Use upstream [FDH2/UxPlay](https://github.com/FDH2/UxPlay)
when full video-mirroring behavior is the priority.

## Audio Format Logging

When an audio session starts, UxPlayEnhanced logs the codec, lossless/lossy
classification, receiver resolution, channel count, and equivalent decoded PCM
bitrate. `ALAC` (`ct=2`) is lossless and `AAC-ELD` (`ct=8`) is lossy.

The current receiver profile is 16-bit/44.1 kHz. The log therefore reports the
format received and decoded by UxPlay; it does not claim to measure the source
service's encoded bitrate or prove that an Apple Music source was Hi-Res
Lossless. Repeated identical DMAP metadata updates are omitted from the console.

## Bonjour-Free Discovery

UxPlayEnhanced replaces UxPlay's Windows Bonjour/DNS-SD dependency with the
embedded responder in `src/dnssd_embedded.c`. It:

- Listens for mDNS on UDP multicast `224.0.0.251:5353`
- Advertises `_airplay._tcp` and `_raop._tcp`
- Responds with PTR, SRV, TXT, and A records
- Sends startup announcements and TTL=0 goodbye records
- Runs in-process without `dnssd.dll`, iTunes, iCloud, or Bonjour services

## Build from Source

Clone this repository with its official UxPlay submodule:

```bash
git clone --recurse-submodules https://github.com/Kylepossible/UxPlayEnhanced.git
cd UxPlayEnhanced
```

Install [MSYS2](https://www.msys2.org/), then install the MinGW64 build
dependencies:

```bash
pacman -S --needed \
  mingw-w64-x86_64-toolchain \
  mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-gstreamer \
  mingw-w64-x86_64-gst-plugins-base \
  mingw-w64-x86_64-gst-plugins-good \
  mingw-w64-x86_64-gst-plugins-bad \
  mingw-w64-x86_64-gst-libav \
  mingw-w64-x86_64-openssl \
  mingw-w64-x86_64-libplist \
  mingw-w64-x86_64-pkg-config
```

The standalone tray executable also requires a Windows Python build environment
with PyInstaller, `pystray`, and Pillow. Run the build from MSYS2:

```bash
bash build.sh
```

The self-contained package is written to `dist/UxPlayEnhanced/`.

## Project Layout

- `lib/uxplay/` — official [FDH2/UxPlay](https://github.com/FDH2/UxPlay) source submodule
- `src/dnssd_embedded.c` — embedded Windows mDNS/DNS-SD implementation
- `patch_cmake.py` — applies the integration, audio-quality, and metadata patches
- `launcher/uxplay_tray.pyw` — UxPlayEnhanced tray application source
- `launcher/UxPlayEnhanced-Setup.*` — installer entry point and setup logic
- `assets/` — application and tray icon assets
- `build.sh` — builds UxPlay, resolves DLL dependencies, and packages the release

## License and Attribution

UxPlayEnhanced uses [FDH2/UxPlay](https://github.com/FDH2/UxPlay) as its core
AirPlay implementation. UxPlay is licensed under LGPL-2.1. See [LICENSE](LICENSE)
and [lib/uxplay/LICENSE](lib/uxplay/LICENSE).

Windows packaging was also informed by
[leapbtw/uxplay-windows](https://github.com/leapbtw/uxplay-windows).
