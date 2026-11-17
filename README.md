# Modem

Share your iPhone's **cellular data** with a Windows PC over a **USB cable**, without
the App Store, without a paid Apple developer account, and without Personal Hotspot.

```
PC apps ──> ModemBridge (Windows) ──USB──> Modem app (iPhone) ──cellular only──> Internet
```

- The iPhone app opens every outgoing connection with iOS's "cellular only" setting,
  so traffic never leaves over Wi-Fi, even if the phone is on Wi-Fi.
- The Windows side routes the whole PC through the phone (or, if you prefer, only
  apps that follow the Windows proxy setting).
- DNS lookups also go through the phone.

## What you need

| | |
|---|---|
| iPhone | iOS 15 or newer, plus a USB cable |
| Windows PC | Windows 10 or 11 |
| Apple ID | Your normal, **free** Apple ID. No developer program needed. |
| GitHub account | Free. GitHub builds the iPhone app on one of its Macs. |
| iTunes and iCloud for Windows | The **apple.com (web) versions**, not the Microsoft Store ones. iTunes provides the USB link to the iPhone; Sideloadly needs both. |
| Sideloadly | Free, from [sideloadly.io](https://sideloadly.io). It signs the app with your Apple ID and installs it. |

`windows\install-prereqs.ps1` installs all of it in one administrator window. Open PowerShell
**as administrator** in the Modem folder and run:

```
powershell -ExecutionPolicy Bypass -File .\windows\install-prereqs.ps1
```

It installs, through winget:

- **iTunes**;
- **Apple Mobile Device Support**, the USB link to the iPhone, which winget's iTunes package
  leaves out;
- **iCloud (Legacy)**, the web version Sideloadly wants.

Sideloadly itself comes straight from sideloadly.io, because its winget entry is out of date.
Its installer is not code-signed by its publisher. If the Microsoft Store versions of iTunes
or iCloud are installed, uninstall them first.

Apple Mobile Device Support also installs Apple's USB tethering driver. If Personal Hotspot
is on, Windows will use it over the cable too. Modem works whether Personal Hotspot is on or
off.

## One-time setup

### 1. Get the iPhone app file

The app is built by GitHub Actions (`.github/workflows/build-ios.yml`) every time
something under `ios/` changes.

1. Open the repository on GitHub, then **Actions**, then **Build iPhone app**.
2. Open the newest successful run and download **Modem-unsigned-ipa** at the bottom.
3. Unzip it. You now have `Modem-unsigned.ipa`.

To rebuild by hand: **Actions**, then **Build iPhone app**, then **Run workflow**.

### 2. Install it on the iPhone with Sideloadly

1. Install iTunes, iCloud and Sideloadly as described above.
2. Plug the iPhone into the PC, unlock it, and tap **Trust**.
3. Open Sideloadly, drag `Modem-unsigned.ipa` into it, type your Apple ID, and click **Start**.
   Enter your Apple ID password or two-factor code if asked.
4. On the iPhone, open **Settings, General, VPN & Device Management**, tap your Apple ID,
   and tap **Trust**.
5. On iOS 16 or newer, turn on **Settings, Privacy & Security, Developer Mode** and restart
   the phone when it asks. (The switch appears after the first sideloaded app is installed.)
6. Open the **Modem** app once. Then check **Settings, Cellular** and make sure Modem is
   allowed to use cellular data.

### 3. Windows side

Nothing to do by hand. The first time you double-click `Start Modem.cmd`, it runs
`windows\setup.ps1`, which:

- downloads [tun2socks](https://github.com/xjasonlyu/tun2socks) v2.7.0 and
  [Wintun](https://www.wintun.net) 0.14.1 into `windows\tools` and checks their SHA-256
  checksums,
- builds `windows\ModemBridge.exe` from `windows\ModemBridge.cs` using the C# compiler
  that comes with Windows.

## Everyday use

1. Plug the iPhone into the PC and open **Modem**. Tethering starts by itself; the dot turns
   green when the app is ready and cellular data is available.
2. On the PC, double-click **`Start Modem.cmd`** and click **Yes** on the administrator prompt.
   Before it changes any Windows network setting, it checks that DNS and a web request
   actually work through the phone. If they don't, it stops and changes nothing.
3. Wait for *"All PC traffic now goes out through the iPhone's cellular data."*
4. To stop, press **Ctrl+C** in that window or just close it. Windows networking goes back
   to normal immediately.

To check the phone path without changing anything (no admin needed), run
`windows\ModemBridge.exe --self-test`. It prints *Self-test passed* when everything works.

**Leave the Modem app running.** With *Keep running when locked* on (the default), the app
plays silence so iOS lets it keep working while the screen is locked or you use other apps.
If you turn that off, the app keeps the screen awake instead.

### Proxy-only mode (no administrator rights)

`Start Modem (proxy only).cmd` points the Windows proxy setting at the phone instead of
routing everything. Browsers and most apps follow it; games and some other programs don't.
Your previous proxy setting is put back when you stop it, and repaired automatically on the
next start if the window was killed.

## Every 7 days: re-install

Apps signed with a free Apple ID stop opening after **7 days**. When that happens, plug the
phone in and run Sideloadly again with the same `.ipa` file. It takes about a minute, and
your settings are kept. (A paid developer account would stretch this to a year; jailbreaking
is the only way to avoid it entirely.)

Sideloadly can also do this for you: its auto-refresh option runs in the background on the
PC and re-signs the app every few days, as long as the PC is on and can reach the phone.

A free Apple ID can have at most 3 sideloaded apps installed at the same time.

## Limits

- **TCP only.** UDP can't cross Apple's USB link, so things that need UDP, such as some games
  and some voice or video calls, won't work. Web browsers quietly fall back from HTTP/3 to TCP,
  so websites are fine. DNS is the exception: ModemBridge converts it to DNS-over-TCP and sends
  it through the phone to 1.1.1.1 (backup 8.8.8.8).
- **IPv4 on the PC side.** The phone itself can still reach IPv6 servers.
- **Speed** is whatever your cellular connection gives you.
- **Carrier rules.** Some plans forbid or cap tethering. Using this may breach your plan's
  terms, and carriers can sometimes detect tethering. That's between you and your carrier.

## Troubleshooting

| What you see | What to do |
|---|---|
| *Can't reach Apple Mobile Device Service* | Install iTunes from apple.com. In **Services**, check that *Apple Mobile Device Service* is running. |
| *No iPhone found on USB* | Try another cable or port, unlock the phone, and tap **Trust**. |
| *The iPhone is connected, but the Modem app is not answering* | Open Modem and tap **Start tethering**. If it won't open, its 7 days are up: re-install with Sideloadly. |
| Modem shows *No cellular data* | Turn on Cellular Data and allow Modem under **Settings, Cellular**. |
| *Untrusted Developer* on the iPhone | **Settings, General, VPN & Device Management**, then trust your Apple ID. |
| *Could not listen for DNS on 127.0.0.1:53* | Another DNS program on the PC is using port 53. Close it. |
| Browsers stopped working after proxy mode crashed | Run either Start file again, or run `windows\ModemBridge.exe --restore-proxy`. |

`windows\ModemBridge.exe --help` lists all options.

## What's in this folder

| Path | What it is |
|---|---|
| `ios/` | The iPhone app (Swift / SwiftUI). `project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec, so no Xcode project is checked in. |
| `.github/workflows/build-ios.yml` | Builds an unsigned `.ipa` on a GitHub Mac. |
| `windows/ModemBridge.cs` | The Windows bridge: USB link to the phone (Apple's usbmux protocol), local proxy, DNS forwarder, tun2socks control, and proxy-mode settings. |
| `windows/setup.ps1` | Downloads tools and builds `ModemBridge.exe`. |
| `Start Modem.cmd`, `Start Modem (proxy only).cmd` | The two ways to start it. |

### How the pieces connect

- **iPhone:** `ProxyServer.swift` listens on port 1080 on the phone's loopback interface,
  which is where USB connections arrive, and refuses anything that didn't come over USB.
  `ProxySession.swift` speaks SOCKS5 and HTTP proxy and opens outgoing connections with
  `requiredInterfaceType = .cellular`.
- **PC:** ModemBridge asks Apple Mobile Device Service (`127.0.0.1:27015`) for a connection
  to port 1080 on the phone, and exposes it on `127.0.0.1:1080`. In full mode, tun2socks
  creates a `ModemTether` network adapter, Windows sends all traffic to it, and tun2socks
  hands it to that proxy. Windows' DNS points at ModemBridge's forwarder on `127.0.0.1:53`.
  Closing the window kills tun2socks, which removes the adapter and its routes.
