# Modem

**Share an iPhone's cellular data with a Windows PC over a USB cable, using a sideloaded app
and no Apple developer account.**

> **Proof of concept. Research and education only.**
> This project was developed and tested in a laboratory environment where such testing and
> access is permitted. If you are anyone else, it is published for research and education
> only, you use it at your own risk, and you are responsible for following the law, your
> carrier's terms and Apple's terms. **Read the full [DISCLAIMER](DISCLAIMER.md) first.**

```
 Windows apps ──► ModemBridge + tun2socks ──USB──► Modem app (iPhone) ──cellular only──► Internet
   (IPv4+IPv6)      virtual adapter           Apple's usbmux          every connection pinned
                    + local proxy + DNS                               to the cellular interface
```

## What it is

- An **iPhone app** (Swift) that runs a SOCKS5 / HTTP proxy on the phone's loopback interface.
  The PC reaches it through Apple's own USB multiplexer, so no network link is needed. Every
  outgoing connection the app makes is pinned to the **cellular** interface; it never uses
  Wi-Fi.
- A **Windows bridge** (C#, compiled with the compiler that ships with Windows) that talks to
  the phone over USB, exposes its proxy on `127.0.0.1:1080`, answers DNS through the phone,
  and, in *full mode*, routes **all** PC traffic (IPv4 and IPv6) through it using
  [tun2socks](https://github.com/xjasonlyu/tun2socks) and
  [Wintun](https://www.wintun.net).
- **Safety checks**: before it touches any Windows network setting it proves that DNS and a
  web request work through the phone, and afterwards it reports whether all traffic really
  leaves through Modem.
- Cloud build and install scripts that need **no Mac** and **no paid developer account**: a
  free Apple ID and [Sideloadly](https://sideloadly.io) are enough.

## What it is not

- It is **not** iOS Personal Hotspot and does not use it. It also is not a VPN: no remote
  server is involved, and Modem adds no encryption.
- It is **not** an App Store app, and cannot become one. iOS gives apps no way to create a
  USB network interface or forward raw packets, which is why this works at the TCP level.
- It is **not** a way around carrier rules, and it makes no claim to hide anything from a
  carrier. See the [DISCLAIMER](DISCLAIMER.md).

## Quick start

Full instructions, with every step and setting, are in **[INSTALL.md](INSTALL.md)**. In short:

1. **Windows prerequisites** (as administrator):
   `powershell -ExecutionPolicy Bypass -File windows\install-prereqs.ps1`
   installs iTunes, Apple Mobile Device Support, iCloud and Sideloadly.
2. **Build the iPhone app** with the *Build iPhone app* GitHub Actions workflow (no Mac
   needed) and download `Modem-unsigned.ipa`.
3. **Install it** on the iPhone with Sideloadly (free Apple ID), then trust the developer,
   turn on Developer Mode (iOS 16+) and allow Modem to use cellular data.
4. **Run it**: plug in the iPhone, open **Modem**, then double-click `Start Modem.cmd` on the PC.

## Everyday use

| Action | How |
|---|---|
| Start (everything through the phone) | Open Modem on the iPhone, then double-click **`Start Modem.cmd`** (or the desktop icon created by `windows\create-shortcut.ps1`) and approve the administrator prompt. |
| Start (browser-type apps only, no admin) | **`Start Modem (proxy only).cmd`**, which sets the Windows proxy. |
| Stop | Press **Ctrl+C** in the Modem window, or close it. Routes and DNS are restored at once. |
| Check the phone path, change nothing | `windows\ModemBridge.exe --self-test` |
| See which connection Windows uses | `windows\ModemBridge.exe --where` |
| Verify routing with byte counters | **`Prove Modem.cmd`** (downloads 25 MB over cellular) |

The phone app must stay running; by default it plays silent audio so iOS lets it continue
while the screen is locked (switch *Keep running when locked*). When full mode is up, the
window prints a green banner once Windows' IPv4 and IPv6 traffic is confirmed to leave
through Modem.

If Modem is the PC's only connection, stopping it takes the PC offline. Keep another
connection available until you trust the setup.

## Status and test results

Tested on **Windows 11 (x64)** with an **iPhone running iOS 26.x** on a carrier whose cellular
network is **IPv6-only** (NAT64). Verified:

- the bridge finds the app over USB by probing ports 41080 to 41089;
- DNS (UDP and TCP) and web requests through the phone; 10 sites loaded in parallel, by name
  and by raw IPv4 address (the latter needs the app's NAT64 handling, see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md));
- full mode: IPv4 and IPv6 both leave through the Modem adapter, with downloads at roughly
  6 to 10 MB/s over cellular;
- failure paths: app not running, Apple's USB service missing, and a phone that refuses
  connections (the bridge reports each clearly and changes nothing).

**Not tested:** other iOS versions or carriers, Windows on ARM64, the 7-day re-signing cycle,
multi-day stability, voice or video calls, games, and anything that needs UDP.

## Limitations

- **TCP only.** UDP cannot cross Apple's USB link, so UDP-based traffic (QUIC, many games,
  many voice and video calls) does not work. Browsers normally fall back to TCP. DNS is
  carried over TCP by the bridge.
- **The app expires every 7 days** when signed with a free Apple ID; re-install it with
  Sideloadly. Free accounts can have at most 3 sideloaded apps at once.
- **Windows only** on the PC side, and it needs Apple's USB components (iTunes and Apple
  Mobile Device Support) from apple.com.
- **The phone app must remain running** and in a state iOS allows to keep it alive.
- **One phone, one PC** at a time.

## Security notes (summary)

- The phone's proxy listens on loopback and refuses anything else, but other apps on the same
  phone can still connect to it, and it has no authentication.
- The PC's local proxy (`127.0.0.1:1080`) and DNS forwarder (`127.0.0.1:53`) are reachable by
  any local process.
- Full mode needs administrator rights and runs downloaded third-party binaries
  (hash-pinned). Use a dedicated Apple ID for Sideloadly.

Details are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [DISCLAIMER.md](DISCLAIMER.md).

## Documentation

| File | Contents |
|---|---|
| [INSTALL.md](INSTALL.md) | Requirements and step-by-step installation, renewal and removal |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Error messages and fixes, including USB and Sideloadly problems |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works, ports, protocols, safety design, security model |
| [DISCLAIMER.md](DISCLAIMER.md) | Intended use, risks, warranty and liability |

## Repository layout

| Path | What it is |
|---|---|
| `ios/` | The iPhone app (SwiftUI). `project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; no Xcode project is checked in. |
| `.github/workflows/build-ios.yml` | Builds an unsigned `.ipa` on a GitHub-hosted Mac. |
| `windows/ModemBridge.cs` | The Windows bridge: usbmux client, local proxy, DNS forwarder, tun2socks control, safety checks, proxy mode. |
| `windows/setup.ps1` | Downloads tun2socks and Wintun (hash-checked) and compiles `ModemBridge.exe`. |
| `windows/install-prereqs.ps1` | Installs iTunes, Apple Mobile Device Support, iCloud and Sideloadly. |
| `windows/create-shortcut.ps1`, `windows/Modem.ico` | Creates the desktop icon. |
| `windows/prove-modem.ps1`, `Prove Modem.cmd` | Byte-counter check of where traffic goes. |
| `Start Modem.cmd`, `Start Modem (proxy only).cmd` | The two ways to start the PC side. |

## License

Copyright © 2026 the repository owner. All rights reserved.

By making this repository public, the owner allows others to view and fork it on GitHub, as
GitHub's Terms of Service provide. **No other licence is granted.** The material is published
for research and education only, as described in the [DISCLAIMER](DISCLAIMER.md). Contact the
owner if you want to use it for anything else.

The third-party software listed in the disclaimer keeps its own licences.
