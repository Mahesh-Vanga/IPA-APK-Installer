# IPA & APK Installer

Install your own signed iPhone, iPad, or Android builds from a native macOS menu bar app. Drag a single IPA or APK onto the icon or into the app, select a compatible device, and click **Install on Device**. Dropping a file does not install it.

## Install

- Open the repository’s [Releases](../../releases) page. Read the notes for the version you want.
- For a signed DMG, open it and copy the app to Applications. For a signed PKG, use the macOS Installer. Choose one format, not both.
- macOS 14 or later is required. Universal packages support Apple silicon and Intel.
- To replace a development build, quit it completely from the menu bar before installing.

## Device setup

| Platform | You need |
| --- | --- |
| iPhone or iPad | Full Xcode selected for command-line tools, paired device, and a device-compatible IPA signed and provisioned for that device. Enable Developer Mode when required. |
| Android | [Google Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools), USB debugging or an existing ADB connection, and a signed standalone APK. |

Refresh devices if your target is not listed. The app does not sign builds, bypass device security, uninstall existing apps, or install app bundles or split APK sets.

## Menu bar

Hover or click the icon to show the drop panel. Drag its title to detach it into the main window. Command-Q closes the app windows but leaves the drop target running. Use the status icon’s double-tap or secondary-click menu to quit completely. Settings controls launch at login, panel close delay, Diagnostics, and update checks.

When the app is idle with all windows closed, it can hand the status icon to a fresh instance to release UI memory. The app preserves the current selection and log locally during that transfer.

## Privacy and development

- [Privacy](docs/PRIVACY.md)
- [Building and releasing](docs/BUILD.md)
- [Contributing](CONTRIBUTING.md)
- [Reporting security issues](SECURITY.md)
- [Changelog](CHANGELOG.md)
- [MIT license](LICENSE)
