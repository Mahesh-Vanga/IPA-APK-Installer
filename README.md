# IPA & APK Installer for macOS

Install your own signed iPhone, iPad, and Android builds from Finder. Drag an IPA or APK onto the menu bar icon or into the installer, select a compatible device, and click **Install on Device**.

## Download

[Get the latest release](https://github.com/Mahesh-Vanga/IPA-APK-Installer/releases/latest)

- **DMG** — open the disk image and drag the app into Applications.
- **PKG** — open the package and follow the macOS Installer prompts.

The same universal app supports Apple silicon and Intel Macs running macOS 14 or later. If you're replacing a development build, fully quit it from the menu bar before installing. Use either installer, not both.

## Device requirements

- **iPhone or iPad** — install and select full Xcode with device support, pair and unlock your device, and enable Developer Mode where required. Use a valid IPA signed and provisioned for that device.
- **Android** — install [Google Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools), enable USB debugging, and authorize the Mac on the device. Use a signed, standalone APK.

The installer doesn't re-sign builds, uninstall apps, or bypass platform security. Device and signing requirements are still enforced by Apple and Android.

## Menu bar and privacy

Hover over the icon to open the drop panel. Press Command-Q to keep the installer in the menu bar, or use the icon's double-tap or secondary-click menu to quit completely. Change the panel's close delay and enable optional launch at login in Settings.

Device installation runs locally. Your builds and diagnostics aren't uploaded. Settings → Updates contacts this GitHub repository only when you choose **Check for Updates**. Canceling a check does not affect local installation.

Report reproducible problems in [Issues](https://github.com/Mahesh-Vanga/IPA-APK-Installer/issues). Include the macOS version, installer version, and device platform. Remove private file paths, device identifiers, and other sensitive details from any logs before posting.
