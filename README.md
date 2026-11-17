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
2. On the PC, double-click the **Modem** icon on the desktop (it runs `Start Modem.cmd`) and
   click **Yes** on the administrator prompt. Before it changes any Windows network setting,
   it checks that DNS and a web request actually work through the phone. If they don't, it
   stops and changes nothing.
3. It then checks where Windows really sends IPv4 and IPv6 traffic and loads a test page the
   normal Windows way. When everything goes through Modem it prints a green banner:
   **"SAFE: all traffic (IPv4 and IPv6) goes through Modem. You can turn off Personal Hotspot
   now."**
4. To stop, press **Ctrl+C** in that window or just close it. Windows networking goes back
   to normal immediately. If Personal Hotspot is off by then, the PC is offline until you
   start Modem again or turn the hotspot back on.

Tools that change nothing (no admin needed):

- `windows\ModemBridge.exe --self-test` checks the phone path and prints *Self-test passed*.
- `windows\ModemBridge.exe --where` shows which connection Windows sends IPv4 and IPv6
  traffic through right now.

### Proving it doesn't count as hotspot data

1. With Modem connected, double-click **`Prove Modem.cmd`**. It downloads 25 MB of test data
   the normal Windows way and shows how many bytes crossed the Modem adapter and how many
   crossed Personal Hotspot (the iPhone's USB Ethernet, or Wi-Fi joined to the hotspot). It
   prints **PASS** when the hotspot carried nothing beyond background noise. With Personal
   Hotspot turned off, nothing can be counted as hotspot data at all.
2. Cross-check on the iPhone: **Settings → Cellular**, then scroll to the list of apps.
   Note the numbers next to **Modem** and **Personal Hotspot**, run `Prove Modem.cmd`, and
   look again. Modem should grow by about 25 MB; Personal Hotspot should not move.
3. Your carrier's own hotspot meter (in its app or account page) is the final word. It often
   lags by hours.

### Why there is nothing to tune on the PC (TTL, TCP window size)

Personal Hotspot forwards the PC's own packets, so the carrier sees Windows' TTL and TCP
behaviour. Modem never forwards a PC packet: the PC's connections end at the app over USB,
and iOS opens brand-new connections to the internet. Every packet on the cellular side
therefore has the iPhone's own TTL, window sizes and TCP options, and iOS counts it as the
Modem app's data. Changing TTL or window sizes on the PC would change nothing the carrier
sees, and window tuning wouldn't speed anything up either, because it only affects the local
hop between Windows and tun2socks.

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
  it through the phone to Cloudflare DNS (one.one.one.one), with Google DNS (dns.google) as backup.
- **IPv4 and IPv6** both go through the phone in full mode. (Personal Hotspot gives this PC
  IPv6; without the IPv6 route, most big sites would keep using the hotspot.)
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
| `windows/prove-modem.ps1`, `Prove Modem.cmd` | Byte-counter proof that traffic uses Modem and not Personal Hotspot. |
| `windows/Modem.ico` | Icon for the desktop shortcut. |
| `Start Modem.cmd`, `Start Modem (proxy only).cmd` | The two ways to start it. |

### How the pieces connect

- **iPhone:** `ProxyServer.swift` listens on the phone's loopback interface, which is where
  USB connections arrive, and refuses anything that didn't come over USB. It uses port
  41080, or the next free port up to 41089 if another app holds it. (1080 is avoided:
  proxy and VPN apps on iPhones commonly take it.) `ProxySession.swift` speaks SOCKS5 and
  HTTP proxy and opens outgoing connections with `requiredInterfaceType = .cellular`.
  Many US carriers' cellular networks are IPv6-only, and there a cellular-pinned
  connection can't reach a raw IPv4 address. `Nat64.swift` finds the carrier's NAT64
  prefix (RFC 7050) and rewrites such addresses into their IPv6 form. Full mode needs this
  because tun2socks only knows IP addresses.
- **PC:** ModemBridge asks Apple Mobile Device Service (`127.0.0.1:27015`) for a connection
  to the app, finding its port by probing 41080-41089, and exposes it on `127.0.0.1:1080`. In full mode, tun2socks
  creates a `ModemTether` network adapter, Windows sends all traffic to it, and tun2socks
  hands it to that proxy. Windows' DNS points at ModemBridge's forwarder on `127.0.0.1:53`.
  Closing the window kills tun2socks, which removes the adapter and its routes.
