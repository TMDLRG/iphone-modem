# Installation guide

This guide takes you from nothing to a working connection. It was written from a real
installation on Windows 11 and an iPhone running iOS 26. Allow about 30 minutes the first
time.

> **Before you start:** this is a proof of concept for research and education. Read the
> [DISCLAIMER](DISCLAIMER.md), and only use it on devices, accounts and networks that you
> own or are authorised to test.

## Requirements

| | |
|---|---|
| iPhone | iOS 15 or newer, with cellular data, and a USB cable |
| PC | Windows 10 or 11, administrator rights, and an internet connection for setup. Tested on x64; ARM64 is supported by the setup script but untested. |
| Apple ID | A free one. **Use a dedicated Apple ID** for sideloading; the password goes to Apple through Sideloadly. |
| GitHub account | Free. GitHub builds the iPhone app on one of its Macs, so you don't need one. |
| Apple's Windows components | **iTunes**, **Apple Mobile Device Support** and **iCloud**, all the **apple.com ("web") versions**, not the Microsoft Store versions. |
| Sideloadly | Free, from [sideloadly.io](https://sideloadly.io) |

Keep a second internet connection available while you set this up, for example the PC's
normal network. Modem becomes the PC's connection only in the last steps.

## Step 1: Install the Windows prerequisites

Open **PowerShell as administrator** in the repository folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install-prereqs.ps1
```

It installs, with `winget`:

- **iTunes** (`Apple.iTunes`),
- **Apple Mobile Device Support** (`Apple.AppleMobileDeviceSupport`), the USB link that Modem
  and Sideloadly both use (winget's iTunes package does not include it),
- **iCloud (Legacy)** (`Apple.iCloud`), the web version that Sideloadly needs,
- **Sideloadly**, downloaded directly from sideloadly.io (its winget entry lags behind). That
  installer is not code-signed by its publisher; the script prints its SHA-256 so you can
  check it.

If the Microsoft Store versions of iTunes or iCloud are installed, uninstall them first.

Check that it worked:

```powershell
Get-Service 'Apple Mobile Device Service'
```

The status should be `Running`. If you prefer to install the pieces by hand, install those
same four items from apple.com and sideloadly.io.

## Step 2: Build the iPhone app (no Mac needed)

The app is built by the GitHub Actions workflow in `.github/workflows/build-ios.yml`, on a
GitHub-hosted Mac, into an **unsigned** `.ipa` that Sideloadly signs for you.

1. **Fork** this repository on GitHub, or push a copy to your own account.
2. In your copy, open the **Actions** tab. If GitHub asks, click **I understand my workflows,
   go ahead and enable them**.
3. Select **Build iPhone app**, click **Run workflow**, and wait for the green tick (about
   3 to 6 minutes).
4. Open the finished run and download the artifact **`Modem-unsigned-ipa`** (a zip file).
   Unzip it to get **`Modem-unsigned.ipa`**.

With the GitHub CLI the same steps are:

```powershell
gh workflow run build-ios.yml --repo <you>/<your-copy>
gh run watch --repo <you>/<your-copy>
gh run download --repo <you>/<your-copy> -n Modem-unsigned-ipa
```

Artifacts expire after a while (GitHub's default is 90 days), so keep the `.ipa` file.

## Step 3: Install the app with Sideloadly

1. Plug the iPhone into the PC, **unlock it**, and tap **Trust** if it asks.
2. Open **Sideloadly**. Check that your iPhone is selected at the top.
3. Drag **`Modem-unsigned.ipa`** onto the IPA icon.
4. Enter your (dedicated) Apple ID and click **Start**. Enter the password and the
   verification code when asked.
5. Wait for *Done*. If it stalls around 88%, unlock the iPhone, close the Modem app if it is
   open, wait a minute, and retry (see the [troubleshooting guide](docs/TROUBLESHOOTING.md)).
6. **Close Sideloadly completely**, including its background helper in the tray. Leaving it
   running can hold the iPhone's USB link and stop Windows from seeing the phone again.

If Apple rejects the app's identifier as already taken, change `PRODUCT_BUNDLE_IDENTIFIER` in
`ios/project.yml` to something unique, rebuild, and install again.

## Step 4: Set up the iPhone

1. **Trust the developer:** *Settings, General, VPN & Device Management*, tap your Apple ID
   under *Developer App*, then **Trust**.
2. **Developer Mode (iOS 16 and newer):** *Settings, Privacy & Security, Developer Mode*, turn
   it on and let the phone restart. After the restart, confirm **Turn On** and enter your
   passcode. This switch appears only after a sideloaded app is installed.
3. **Cellular data:** *Settings, Cellular*, scroll to the app list and make sure **Modem** is
   switched on. Cellular data itself must be on.
4. Open **Modem**. After a moment it shows **Tethering on** and a status like
   **Ready for the PC over USB (port 41080)**. If another app on the phone already uses
   port 41080, Modem picks the next free port up to 41089 and lists the change under *Recent
   events*; the PC side finds it automatically.
5. **Location, so phone calls don't cut the connection:** the first time Modem opens it asks
   for location access. Choose **Allow While Using App**. Modem uses it only as a reason for
   iOS to keep it running when you answer a call (it asks for the coarsest location and
   discards every location it receives), and the line under *Keep running during calls* should
   then read *On*. Without it, answering a call suspends Modem and the PC loses its
   connection until you open Modem again. You can refuse or switch the option off; everything
   else works.

If Windows no longer sees the iPhone after the Developer Mode restart, unplug and re-plug the
cable and, if that doesn't help, restart the PC (see the troubleshooting guide).

## Step 5: Set up the Windows side

Run the setup script once, in the repository folder (no administrator rights needed):

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\setup.ps1
```

It:

- downloads **tun2socks v2.7.0** and **Wintun 0.14.1** into `windows\tools\` and checks both
  against pinned SHA-256 hashes (it refuses to install anything that doesn't match),
- compiles **`windows\ModemBridge.exe`** from `ModemBridge.cs` with the C# compiler that comes
  with Windows (no SDK needed),
- reports whether Apple Mobile Device Service is installed.

(`Start Modem.cmd` runs this automatically if the files are missing.)

Then, with the iPhone plugged in and **Modem open on it**, try the check that changes nothing:

```powershell
windows\ModemBridge.exe --self-test
```

It must end with *Self-test passed*. If it doesn't, see the
[troubleshooting guide](docs/TROUBLESHOOTING.md) before going on.

## Step 6: Start it

1. Keep your other internet connection on for now.
2. Double-click **`Start Modem.cmd`** and click **Yes** on the administrator prompt.
3. The bridge first checks that DNS and a web request work through the phone. If they don't,
   it stops and changes no setting.
4. It then sets up routing and reports where Windows sends IPv4 and IPv6 traffic. When both go
   through Modem you get a green **SAFE** banner.
5. Check it any time with `windows\ModemBridge.exe --where`, and with **`Prove Modem.cmd`**,
   which downloads 25 MB and compares the bytes that crossed the Modem adapter with those
   that crossed any other connection.

To stop, press **Ctrl+C** in the bridge window or close it. Windows networking returns to
normal immediately.

### Optional: a desktop icon

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\create-shortcut.ps1
```

This puts a **Modem** shortcut on your desktop that runs `Start Modem.cmd`.

### Optional: proxy-only mode

`Start Modem (proxy only).cmd` sets the per-user Windows proxy to the phone instead of routing
everything, and needs no administrator rights. Browsers and many apps follow it; others
don't. Your previous proxy setting is saved first and restored when you stop (or repaired at
the next start if the window was killed). Restore it by hand with
`windows\ModemBridge.exe --restore-proxy`.

## Renewing every 7 days

Apps signed with a free Apple ID stop opening after 7 days. Before that, plug the phone in and
run Sideloadly again with the same `.ipa` and Apple ID. It takes about a minute and keeps the
app's data. Sideloadly also has an automatic refresh option, but its background helper has
been seen holding the iPhone's USB link on some systems, so refreshing by hand is safer.

**Do the renewal while another internet connection is available**, because installing disturbs
the USB link. If the app expires first, it simply won't open; reconnect another way and
re-install.

## Updating

Pull the new source, run the *Build iPhone app* workflow again, install the new `.ipa` with
Sideloadly (it replaces the old app), and delete `windows\ModemBridge.exe` so that
`windows\setup.ps1` rebuilds it from the new source.

## Removing everything

1. Close the bridge window (this removes the `ModemTether` adapter and its routes).
2. Delete the Modem app from the iPhone, and turn Developer Mode off if you no longer need it.
3. In Sideloadly, close the app; uninstall it from *Settings, Apps* on the PC if you like.
4. Delete the repository folder, and the desktop icon if you made one. Uninstall iTunes,
   iCloud and Apple Mobile Device Support from *Settings, Apps* if you don't need them.
