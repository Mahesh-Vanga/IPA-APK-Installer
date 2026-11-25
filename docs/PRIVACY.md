# Privacy

IPA and APK files, device information, and diagnostics are not uploaded by the installer. No account, analytics, or automatic update checks are required. A user-requested update check reads release metadata from the configured public GitHub repository. It can be canceled, and installing to a local device does not depend on it.

Device operations use Apple's Xcode tooling or Android Platform-Tools on the Mac. Use trusted copies from their respective vendors. The app stages files in a private temporary directory during validation and installation. The menu bar idle handoff briefly writes session information in another private temporary directory and removes it after a normal transfer. A crash or forced termination may leave temporary files behind.

Diagnostic logs can contain filenames, paths, device identifiers, and tool output. Redact this information before sharing a report. Never upload a signed build, provisioning profile, credential, or full diagnostic log to a public issue.
