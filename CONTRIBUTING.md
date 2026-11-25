# Contributing

For a change, explain the user-visible behavior and how you tested it. Run `bash test-core.sh` and, for UI or packaging changes, build both installer formats locally.

Use synthetic archives and device identifiers in tests. Keep installation explicit, validate files before using them, and do not add background network requests or telemetry. Do not commit credentials, screenshots with personal information, provisioned builds, signing identities, or diagnostics from real devices.
