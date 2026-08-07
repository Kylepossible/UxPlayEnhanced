# UxPlay-NoBojour

**AirPlay receiver for Windows — no Bonjour service required.**

Mirror your iPhone, iPad, or Mac screen and audio to your Windows PC using AirPlay, without needing Apple's Bonjour service installed.

This project is a fork/wrapper around [UxPlay](https://github.com/FDH2/UxPlay) that replaces the Bonjour/DNS-SD dependency with a built-in embedded mDNS responder. Zero external services needed.

## What's Different

| | Standard UxPlay | This Fork |
|---|---|---|
| **Bonjour Service** | Required (mDNSResponder.exe) | Not needed |
| **mDNS Discovery** | Via external `dnssd.dll` IPC | Built-in, runs in-process |
| **Extra Install** | iTunes/iCloud/Bonjour SDK | Nothing — fully self-contained |
| **Latency** | IPC overhead to Bonjour service | Direct multicast, lower latency |

### How It Works

The `dnssd_embedded.c` file is a drop-in replacement for UxPlay's `dnssd.c`. Instead of loading Apple's `dnssd.dll` and communicating with the Bonjour Windows service, it:

1. Starts a lightweight background thread listening on UDP multicast `224.0.0.251:5353`
2. Responds to mDNS queries for `_airplay._tcp` and `_raop._tcp` services
3. Sends proactive mDNS announcements when the server starts
4. Sends goodbye packets (TTL=0) on shutdown so clients flush stale caches
5. Implements TXT record encoding inline — no external library needed

Total overhead: one thread doing `select()` with a 1-second timeout. Near-zero CPU when idle.

## Quick Start (Pre-built)

1. Download the latest release from [Releases](../../releases)
2. Extract to any folder
3. Run `setup-firewall.ps1` as Administrator (first time only — allows UxPlay through Windows Firewall)
4. Run `UxPlay.bat` (console) or `uxplay_tray.pyw` (system tray icon, requires Python 3 + `pip install pystray pillow`)
5. On your Apple device: **Control Center > Screen Mirroring** > select your PC's name

## Building from Source

### Prerequisites

Install [MSYS2](https://www.msys2.org/), then in a **MinGW64** shell:

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

### Build

```bash
git clone --recurse-submodules https://github.com/YOUR_USERNAME/uxplay-nobonjour.git
cd uxplay-nobonjour
bash build.sh
```

The self-contained output goes to `dist/UxPlay/`.

### Manual Build

If you prefer to build manually:

```bash
# Apply the embedded mDNS patch
python patch_cmake.py

# Build
mkdir build && cd build
cmake ../lib/uxplay -G "MinGW Makefiles" -DUSE_EMBEDDED_MDNS=ON -DNO_MARCH_NATIVE=ON -DCMAKE_BUILD_TYPE=Release
mingw32-make -j$(nproc)
```

## Usage

```
uxplay.exe [options]
```

Key options:
| Flag | Description |
|------|-------------|
| `-n name` | Name shown on Apple devices (default: hostname) |
| `-nh` | Don't append hostname suffix to the name |
| `-vs 0` | Audio-only mode; disables the local video renderer |
| `-h265` | Enable H.265/4K video support |
| `-vsync` | Sync audio to video (recommended) |
| `-pin` | Require a PIN code for connections |
| `-d` | Debug output |

Run `uxplay.exe --help` for all options.

The included `UxPlay.bat`, tray launcher, and debug launcher default to
audio-only mode. This avoids starting the local video decode/render pipeline,
reducing CPU/GPU use and video-related timing pressure. Use the raw command
line with a video sink such as `-vs autovideosink` when screen mirroring is
wanted.

### Audio Format Logging

When an AirPlay audio session starts, UxPlay logs the codec, lossless/lossy
classification, receiver resolution, channel count, and equivalent decoded
PCM bitrate. `ALAC` (`ct=2`) is lossless; `AAC-ELD` (`ct=8`) is lossy. The
current Windows receiver profile is fixed at 16-bit/44.1 kHz, so the log does
not claim to measure an encoded ALAC bitrate or Hi-Res Lossless source rate.
Repeated unchanged DMAP metadata updates are suppressed in the console; a
metadata block is printed again only when its contents change or a new audio
session starts.

## Firewall Setup

Windows Firewall blocks incoming connections by default. Run `setup-firewall.ps1` as Administrator once to create allow rules for `uxplay.exe` (TCP + UDP inbound).

## System Tray Launcher

`uxplay_tray.pyw` runs UxPlay hidden with a system tray icon. Requires:

```
pip install pystray pillow
```

Right-click the tray icon to restart or quit.

## Technical Details

### Embedded mDNS Implementation

The embedded responder (`lib/uxplay/lib/dnssd_embedded.c`) implements:

- **RFC 6762** (Multicast DNS) — joins `224.0.0.251:5353`, responds to queries
- **RFC 6763** (DNS-SD) — registers `_airplay._tcp` and `_raop._tcp` services
- **DNS record types**: PTR, SRV, TXT, A with proper TTLs and cache-flush bits
- **One-shot discovery**: PTR responses include SRV+TXT+A in the additional section
- **Announcements**: 3x multicast announcements on service registration (250ms apart)
- **Goodbye packets**: TTL=0 records on unregistration

### CMake Integration

The `USE_EMBEDDED_MDNS` CMake option (default OFF in upstream, ON in this project) swaps `dnssd.c` for `dnssd_embedded.c` and skips all Bonjour/Avahi SDK detection. The build-time patch also adds the audio-quality log and suppresses repeated unchanged metadata blocks in `uxplay.cpp`.

## Credits

- [UxPlay](https://github.com/FDH2/UxPlay) by FDH2 — the core AirPlay server
- [leapbtw/uxplay-windows](https://github.com/leapbtw/uxplay-windows) — inspiration for the Windows packaging approach
- Embedded mDNS implementation by Claude (Anthropic)

## License

LGPL 2.1 — same as UxPlay. See [LICENSE](LICENSE) and [lib/uxplay/LICENSE](lib/uxplay/LICENSE).
