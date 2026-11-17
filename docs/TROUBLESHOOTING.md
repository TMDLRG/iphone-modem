# Troubleshooting

Start with the two checks that change nothing:

```powershell
windows\ModemBridge.exe --self-test    # does the PC reach the internet through the phone?
windows\ModemBridge.exe --where        # which connection does Windows use right now?
```

## Messages from the bridge

| Message | Meaning and fix |
|---|---|
| *Can't reach Apple Mobile Device Service at 127.0.0.1:27015* | Apple's USB service isn't running or installed. Run `windows\install-prereqs.ps1`, or install iTunes from apple.com, and check that the **Apple Mobile Device Service** service is running. |
| *No iPhone found on USB* | Try another cable or port, unlock the phone and tap **Trust**. If Windows lists the phone but the bridge doesn't, see [the iPhone vanished from Apple's service](#the-iphone-vanished-from-apples-service). |
| *The iPhone is only visible over Wi-Fi* | Connect it with a USB cable. |
| *The iPhone is connected, but the Modem app is not answering* | Open **Modem** on the iPhone and check that it says *Tethering on*. If the app won't open, its 7 days may be up: re-install it (see [INSTALL.md](../INSTALL.md)). |
| *The iPhone was disconnected* | Plug the cable back in. |
| *Safety check failed ... No Windows network settings were changed* | The phone could not resolve a name or fetch a web page. See [cellular problems](#the-app-is-running-but-nothing-loads). Nothing was changed on the PC. |
| *Port 1080 on this PC is already in use* | Close the other program, or pass `--port N`. |
| *Could not listen for DNS on 127.0.0.1:53* | Another DNS service on the PC is using port 53. Close it. |
| *tun2socks.exe not found ... Run setup.ps1 first* | Run `powershell -ExecutionPolicy Bypass -File windows\setup.ps1`. |
| *NOT SAFE to turn off ... traffic is not going through Modem* | Windows still sends some traffic elsewhere. Close the window to undo, then run `--where`. Early versions judged too soon after setup and could print this by mistake; the current version waits up to 30 s. |
| *Administrator permission was declined* | Full mode needs it. Use `Start Modem (proxy only).cmd`, which doesn't. |

## On the iPhone

| What you see | What to do |
|---|---|
| The app won't open: *Untrusted Developer* | *Settings, General, VPN & Device Management*, tap your Apple ID, **Trust**. |
| The app won't open, mentions Developer Mode | *Settings, Privacy & Security, Developer Mode*, turn it on and restart the phone. The switch appears only after a sideloaded app is installed. |
| The app won't open at all after about a week | The free-Apple-ID signature expired. Re-install with Sideloadly. |
| Status: *Port NNNN is busy, trying ...* | Another app on the phone holds that port. Modem tries 41080 to 41089 by itself; the line under *Tethering on* shows the port it settled on. |
| Cellular section: *No cellular data* | Turn on Cellular Data and make sure **Modem** is switched on under *Settings, Cellular*. |
| *Recent events*: *Could not reach ... posix error 50 (network down)* | Raw IPv4 on an IPv6-only cellular network. Use a build that includes the NAT64 handling (`Nat64.swift`), which is in the current source. |

### The app is running but nothing loads

1. Check *Settings, Cellular*: Cellular Data on, and **Modem** on in the app list.
2. Check that the phone itself has working cellular data (open a web page with Wi-Fi off).
3. Look at *Recent events* in the app for the exact error, and at the bridge window.

## Sideloadly

| What you see | What to do |
|---|---|
| Stuck around **88%** | Unlock the phone and keep the screen on, close the Modem app if it is open, wait a minute, and retry. An interrupted install does not harm the phone; the old version stays. |
| Apple ID or two-factor errors | Sign in at account.apple.com first, and use a dedicated Apple ID. |
| *Bundle identifier is not available* | Change `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` to something unique, rebuild and reinstall. |
| `winget` reports a hash mismatch for Sideloadly | Expected: the winget entry lags behind the website. `windows\install-prereqs.ps1` downloads the installer from sideloadly.io instead. |

## The iPhone vanished from Apple's service

**Symptom:** Windows Device Manager shows the iPhone, and USB tethering may still work, but
`--self-test` says no iPhone was found and Apple's service lists no devices.

This was seen once, on a Windows 11 machine, after the phone restarted for Developer Mode
while Sideloadly's background helper was running. The iPhone's USB data interface (`MI_01`,
the "usbmux" one) was left *Disabled*, and `pnputil` commands that restart or remove it
hung. Restarting the Apple service, re-plugging the cable and trying other ports did not
help; **restarting the PC did**. The cause is suspected, not proven.

To look at the state:

```powershell
pnputil /enum-interfaces /class "{f0b32be3-6678-4879-9230-e43845d805ee}"
```

*Interface Status: Disabled* for the iPhone's entry is the bad state. What to do:

1. Close Sideloadly completely (including its tray helper), unplug the cable, wait a few
   seconds, and plug it back in with the phone unlocked.
2. If that doesn't help, **restart the PC**. Do **not** run `pnputil /restart-device` or
   `/remove-device` on the iPhone's interface; they hung in testing.
3. After the restart, don't open Sideloadly until the bridge can see the phone.

Prevention: install, then close Sideloadly; don't leave its helper running.

## Windows networking

| What you see | What to do |
|---|---|
| The PC is offline after you stop Modem | Expected if Modem was the only connection. Reconnect another way. |
| Browsers broke after proxy mode crashed | Start either launcher again, or run `windows\ModemBridge.exe --restore-proxy`. |
| A leftover `ModemTether` adapter | Close any running bridge window; the adapter goes with tun2socks. If it persists, restart the PC. |
| IPv6 sites don't work | Full mode routes IPv6 through the phone as well; run `--where` to check both families. Proxy-only mode covers only apps that use the Windows proxy. |
| UDP-based apps (games, calls) fail | Not supported: UDP can't cross the USB link. |

## Rebuilding the bridge

`windows\ModemBridge.exe` is compiled by `windows\setup.ps1`. To rebuild after editing
`ModemBridge.cs`, run `setup.ps1` again; it recompiles when the source is newer. A running
copy can be renamed but not overwritten or deleted, so stop the bridge first (or rename the
running file aside).
