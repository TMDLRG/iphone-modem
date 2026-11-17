# How Modem works

This document describes the design as built and tested. See the [DISCLAIMER](../DISCLAIMER.md)
before using any of it.

## The problem

iOS does not let an app create a USB network interface or forward raw packets, so a true
"USB modem" app is impossible. What an app *can* do is run a proxy server and open its own
network connections. Modem uses exactly that:

```
PC app ─► Wintun adapter "ModemTether" ─► tun2socks ─► 127.0.0.1:1080 (ModemBridge)
                                                              │  Apple's usbmuxd, 127.0.0.1:27015
                                                              ▼
                                  USB cable ──► Modem app, 127.0.0.1:41080 on the iPhone
                                                              │  new connection, cellular only
                                                              ▼
                                                          Internet
```

The PC's TCP connections end at tun2socks (which re-presents them as SOCKS5 requests). The
iPhone app then opens a **new, separate** connection to each destination, forced onto the
cellular interface. That separation is what makes the traffic leave "as the iPhone", and it
is also why only TCP is supported.

## Components

### iPhone app (`ios/Modem/`, Swift 5, SwiftUI, iOS 15+)

| File | Role |
|---|---|
| `ProxyServer.swift` | Listens on the phone's **loopback** interface. Tries ports **41080 to 41089** in order and moves on if one is in use ("address in use"). Refuses any client that is not on loopback (usbmux-forwarded connections arrive from loopback). Counts traffic. |
| `ProxySession.swift` | One client connection. Speaks **SOCKS5** (no auth, `CONNECT` only) and **HTTP proxy** (`CONNECT` tunnels and plain `http://` requests, rewritten to origin form with `Connection: close`). Opens upstream connections with `requiredInterfaceType = .cellular` and Wi-Fi, wired and loopback prohibited. Relays both ways with flow control and half-close handling. Timeouts: 30 s for a request to arrive, 30 s to connect, 60 s idle once one side has closed. |
| `Nat64.swift` | Makes IPv4 literals work on IPv6-only cellular networks (see below). |
| `BackgroundKeeper.swift` | Plays a silent, looping audio file so iOS keeps the app running when the screen locks (`UIBackgroundModes: audio`). Resumes after calls, alarms and audio-service resets. |
| `TetherController.swift` | App state; watches cellular availability with `NWPathMonitor`; starts and stops the proxy and the background audio. |
| `ContentView.swift`, `ModemApp.swift` | The UI: status, cellular state, traffic counters, the *Keep running when locked* option and recent events. |

The app needs no special entitlement, which is why a free Apple ID can sign it.

### Windows bridge (`windows/ModemBridge.cs`, C# 5)

Compiled by `windows/setup.ps1` with the `csc.exe` that ships with the .NET Framework in
Windows, so no SDK is needed.

| Part | Role |
|---|---|
| `UsbMux`, `Plist` | A minimal client for Apple's **usbmuxd** protocol (version 1, XML-plist messages) on `127.0.0.1:27015`: `ListDevices` to find the USB-attached phone, and `Connect` to open a TCP stream to a port on it. |
| `PhoneLink` | Finds the phone and the app's port (probes 41080 to 41089 with a SOCKS5 greeting; `--phone-port` overrides), re-resolves after a re-plug or app restart, and explains failures. |
| `Forwarder` | Accepts connections on `127.0.0.1:1080` and pipes each one to a fresh usbmux stream. |
| `DnsForwarder` | Listens on `127.0.0.1:53` (UDP and TCP) and sends each query as **DNS over TCP** through the phone to `one.one.one.one` (then `dns.google`). Replies SERVFAIL if all fail. |
| `Tunnel` | Starts **tun2socks** against the local proxy, waits for the `ModemTether` adapter, assigns `198.18.77.1/24` and `fd77:7e7e::1/64`, points the adapter's DNS at `127.0.0.1`, and adds IPv4 and IPv6 default routes at metric 1. Then `Verify` reports which adapter Windows picks as the source for IPv4 and IPv6 internet addresses and loads a test page the normal way. |
| `SystemProxy` | Proxy-only mode: sets the per-user WinINet proxy and keeps a backup of the old values in `%LOCALAPPDATA%\ModemBridge\proxy-backup.txt`. |
| `Program` | Option parsing, elevation, the `--self-test`, `--where` and `--restore-proxy` commands, and cleanup. |

### Cloud build (`.github/workflows/build-ios.yml`)

On a GitHub-hosted macOS runner: install XcodeGen, `xcodegen generate` (from
`ios/project.yml`), `xcodebuild` for `iphoneos` with code signing **off**, and zip
`Payload/Modem.app` into `Modem-unsigned.ipa`. Sideloadly signs it with the user's Apple ID.
The Xcode version comes from the runner image and is not pinned.

## Ports and addresses

| What | Value |
|---|---|
| iPhone proxy | `127.0.0.1`, first free port of 41080 to 41089 (on the phone) |
| usbmuxd on the PC | `127.0.0.1:27015` (Apple Mobile Device Service) |
| PC proxy (SOCKS5 and HTTP) | `127.0.0.1:1080` |
| PC DNS forwarder | `127.0.0.1:53` |
| Tunnel adapter | `ModemTether`: `198.18.77.1/24` and `fd77:7e7e::1/64` (private ranges) |

## IPv6-only cellular networks (NAT64)

Some carriers run IPv6-only cellular networks. There, a connection **pinned to the cellular
interface** cannot reach a raw IPv4 address such as `1.1.1.1`: iOS reports "network is down"
(POSIX error 50). Names work, because the carrier's DNS64 returns usable IPv6 addresses for
them. tun2socks, however, only ever knows IP addresses. `Nat64.swift` therefore:

1. discovers the carrier's NAT64 prefix (RFC 7050: resolve `ipv4only.arpa` over cellular;
   falls back to `64:ff9b::/96`),
2. retries an IPv4 destination that failed with a no-route error at the synthesised IPv6
   address (prefix plus the IPv4 address, RFC 6052), and
3. goes straight to the synthesised address once that has worked, or when the cellular path is
   known to be IPv6-only.

The bridge's DNS servers are given by name for the same reason.

## Safety design

- **Prove first, change later.** Full and proxy modes resolve a name and fetch a web page
  through the phone *before* touching any route, DNS or proxy setting. If either fails, nothing
  is changed. `--self-test` runs the same check on its own.
- **Verify after.** After routing, the bridge waits up to 30 s for Windows to activate the new
  addresses and then checks the source address Windows uses for IPv4 and IPv6 internet
  destinations. It prints SAFE only when both leave through Modem and a test page loads the
  normal way.
- **Everything undoes itself.** tun2socks runs inside a Windows *job object* that kills it when
  the bridge exits, which removes the adapter and its routes. The system-proxy backup is
  restored on exit and repaired at the next start if the window was killed.
- **Both address families are routed.** A PC that has IPv6 from another connection would
  otherwise keep using it for IPv6 traffic.
- **Loopback only.** The phone refuses clients that are not on loopback, and the PC listens
  only on `127.0.0.1`.
- **Hash-pinned downloads.** `setup.ps1` checks tun2socks and Wintun against SHA-256 values in
  the script and deletes anything that doesn't match.

## Security model and known weaknesses

| Topic | Reality |
|---|---|
| Authentication | None. Anything that can reach `127.0.0.1:41080` on the phone (including other apps on the phone) or `127.0.0.1:1080` / `:53` on the PC can use them. |
| Encryption | Modem adds none. TLS traffic stays end to end; plain traffic is visible on the way, as usual. |
| Privileges | Full mode runs elevated to create the adapter and routes. |
| Third-party code | tun2socks and Wintun (hash-pinned), Apple's drivers, Sideloadly (unsigned installer). |
| Credentials | Sideloadly sends the Apple ID credentials to Apple; use a dedicated account. |
| Visibility | The destinations, volumes and timing of traffic remain visible to the carrier and the network. Nothing here is designed to hide them. |

### Why there is no PC-side TCP/IP tuning

Because the PC's TCP connections end at tun2socks and the phone opens new ones, the packets on
the cellular link are produced by iOS, not forwarded from Windows. Windows-side parameters
such as TTL or TCP window size therefore do not reach the cellular network, and tuning them
changes nothing there. (For the same reason this document makes no claim that the traffic is
indistinguishable from anything else.)

## Findings from testing

- **Apple's Windows usbmuxd reports `Connect` as successful even when nothing listens** on the
  phone's port, then closes the stream at once. The bridge treats that as "app not
  answering".
- **Port 1080 was already taken on the test phone**, which is why the default is 41080 with
  automatic fallback.
- **Raw IPv4 failed on an IPv6-only carrier** until NAT64 handling was added.
- **The iPhone can vanish from Apple's Windows service** after the phone restarts (for example
  for Developer Mode) while Sideloadly's background helper is running; the usbmux interface
  ended up *Disabled* and `pnputil` restart and remove commands hung. A PC restart fixed it.
  The cause is suspected, not proven.

## Not built (ideas)

UDP (impossible over a stream-only USB link), ICMP, per-application routing, authentication
on the phone-side proxy, starting automatically with Windows, and a signed installer.
