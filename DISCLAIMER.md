# Disclaimer

**Please read this before you download, build, install or run anything from this repository.**

## 1. Status: proof of concept

Modem is an experimental **proof of concept (PoC)**. It is not a product and not production
software. It comes with no support, no roadmap and no guarantee that it works on your
devices. It can stop working at any time because of changes in iOS, Windows, Apple's USB
drivers, Sideloadly, a mobile carrier's network, or the third-party tools it relies on.

## 2. Where and how it was developed

The author developed and tested this software in a laboratory environment in which this
kind of testing, and the network and device access it needs, is permitted. Nothing in this
repository says or implies that the same use is permitted for you, on your devices, with
your accounts, or on your networks.

## 3. Intended use by others: research and education only

The source code and documentation are published **for research and education only**: to
study how the pieces fit together, to reproduce the results in an environment that you own
or are explicitly authorised to test, and for teaching. They are **not** intended for
production, commercial or operational use, and not for use on any device, account or network
that you do not own and have not been given explicit permission to test.

No licence is granted beyond that intent (see the *License* section of the [README](README.md)).

## 4. You are responsible for compliance

You alone are responsible for making sure that your use complies with:

- **The law** that applies to you, including laws on computer and network access.
- **Your mobile carrier's agreements and policies.** Many plans restrict, meter, throttle or
  prohibit tethering and hotspot use, and carriers may detect it and act on it, for example
  with extra charges, throttling or suspension of the line.
- **Apple's terms**, including those for your Apple ID, for sideloading apps, and for Developer
  Mode on the iPhone.
- **Employer, school and network-owner policies** for any computer or network you connect.
- **The licences and terms of the third-party software** this project uses (see below).

The author does not encourage or assist anyone in getting around the restrictions, metering
or technical measures that a carrier or network operator has put in place. Nothing here claims
that this software avoids detection or accounting by any carrier or network operator, and it
was not designed to.

## 5. Specific risks

- **Network changes.** Full mode changes this PC's routes and DNS settings; proxy-only mode
  changes the per-user Windows proxy setting. A fault, or stopping Modem while no other
  connection is available, can leave the PC without internet access.
- **Administrator rights and downloaded programs.** Full mode runs with administrator rights.
  Setup downloads third-party programs from the internet (checked against pinned SHA-256
  hashes, but still third-party code), and the installer for Sideloadly is, at the time of
  writing, not code-signed by its publisher.
- **Apple ID credentials.** Sideloadly asks for your Apple ID and password, and sends them to
  Apple. Use a separate, dedicated Apple ID for sideloading rather than your main account.
- **The phone-side proxy is unauthenticated.** It accepts connections only from the phone's
  own loopback interface (which is how the USB link arrives), but any app running on the
  same iPhone can also connect to it while Modem is running.
- **No added encryption.** Modem does not encrypt traffic itself. Connections that are
  already encrypted (for example HTTPS) stay encrypted end to end; plain connections are
  visible to the phone, to your carrier and to the network, as with any other connection.
- **Data use and charges.** Everything the PC does uses the phone's cellular data. Updates,
  backups and cloud sync can use a lot of it.
- **System side effects.** Apple's Windows USB components can get stuck after the phone
  restarts or is re-plugged (see the troubleshooting guide). Recovery can require restarting
  the PC.
- **The app expires.** An app signed with a free Apple ID stops opening after 7 days. If the
  PC depends on it as its only connection, plan for that.

## 6. No warranty and limitation of liability

THE SOFTWARE AND DOCUMENTATION ARE PROVIDED "AS IS" AND "AS AVAILABLE", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE, NON-INFRINGEMENT, ACCURACY AND AVAILABILITY. TO THE FULLEST EXTENT
PERMITTED BY LAW, THE AUTHOR AND CONTRIBUTORS ARE NOT LIABLE FOR ANY CLAIM, DAMAGE, LOSS OR
COST OF ANY KIND ARISING FROM OR RELATED TO THE SOFTWARE OR ITS USE, INCLUDING LOSS OF
DATA OR CONNECTIVITY, CARRIER CHARGES OR ACCOUNT ACTION, DEVICE OR ACCOUNT PROBLEMS, AND
LOSS OF PROFITS, WHETHER IN CONTRACT, TORT OR OTHERWISE, EVEN IF ADVISED OF THE POSSIBILITY.
YOU USE IT ENTIRELY AT YOUR OWN RISK.

## 7. Trademarks and affiliation

Apple, iPhone, iOS, iTunes, iCloud and Windows, and other product names, are trademarks of
their respective owners. This project is independent. It is not affiliated with, endorsed by,
or sponsored by Apple, Microsoft, any mobile carrier, or any of the third-party projects named
below.

## 8. Third-party software

Modem builds on separate projects that have their own licences and terms. None of them is
included in this repository; they are downloaded at setup time or installed by you.

| Software | Used for | Where it comes from |
|---|---|---|
| [tun2socks](https://github.com/xjasonlyu/tun2socks) (MIT) | Turning the PC's traffic into proxy connections | Downloaded by `windows/setup.ps1` (v2.7.0, SHA-256 pinned) |
| [Wintun](https://www.wintun.net) | Virtual network adapter for tun2socks | Downloaded by `windows/setup.ps1` (0.14.1, SHA-256 pinned); subject to Wintun's own licence |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT) | Generating the Xcode project in the cloud build | Installed with Homebrew on the GitHub build machine |
| Apple Mobile Device Support, iTunes, iCloud | USB link to the iPhone | Installed from Apple by you or by `windows/install-prereqs.ps1` |
| [Sideloadly](https://sideloadly.io) | Signing and installing the app with an Apple ID | Installed from sideloadly.io by you or by `windows/install-prereqs.ps1` |

## 9. Changes

This disclaimer may change over time. The version in the default branch of this repository
is the current one.
