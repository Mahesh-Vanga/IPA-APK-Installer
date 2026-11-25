# Build and verify

Requirements are a Mac running macOS 14 or later, Xcode or its command-line tools, and the macOS SDK. Full Xcode is required at runtime for Apple-device operations. There are no bundled SDKs, external Swift packages, or signing credentials.

```sh
bash test-core.sh
BUILD_UNIVERSAL=1 BUILD_PKG=1 bash build-dmg.sh
```

Local builds go to `dist/`. They are for development, not Gatekeeper-ready public distribution. Tests use synthetic fixtures and mock ADB. They do not install to physical devices.

## Distribution checklist

1. Run the fixture suite and inspect the clean source tree and release assets for private paths, personal data, secrets, device identifiers, and signing materials.
2. Build with `BUILD_UNIVERSAL=1`, `BUILD_PKG=1`, a suitable Developer ID Application identity in `SIGN_IDENTITY`, and a Developer ID Installer identity in `INSTALLER_SIGN_IDENTITY`. Use a project or organization identity if the publisher's personal name must not appear in the public signature. Pass the public repository slug in `UPDATE_REPOSITORY` to enable official manual update checks.
3. Submit the DMG and PKG to Apple notarization from a private signing environment. Staple and validate both tickets. Do not commit Keychain profiles, certificates, private keys, developer machine credentials, or submission logs.
4. Verify the universal app and the payload signatures, check Gatekeeper acceptance for DMG and PKG, and generate SHA-256 checksums **after** stapling.
5. Attach verified artifacts and checksums to a versioned GitHub release. Document the supported platforms, changes, known limits, and what was actually tested.
