# Contributing to Perch / 参与贡献

感谢你愿意参与！Issue 和 PR 用中文或英文都可以。
Thanks for helping out! Issues and pull requests are welcome in Chinese or English.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
Report security problems privately, as described in [SECURITY.md](SECURITY.md). Never use a public issue for them.

## Getting set up

1. Requirements: macOS with **Xcode 26+** (iOS 26 SDK, Swift 6). For the end-to-end test you also need an Apple silicon Mac.
2. Clone and configure signing:

   ```sh
   git clone https://github.com/bulai0408/Perch.git
   cd Perch
   cp Config/Local.example.xcconfig Config/Local.xcconfig
   ```

   Put your own `PERCH_BUNDLE_ID` and `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`, which is gitignored. You only need this to run on a device; Simulator builds work without it.
   **Never commit `Config/Local.xcconfig`, and never put a team id or bundle id in `project.pbxproj`.**
3. Open `Perch.xcodeproj` and run the `Perch` scheme.

For UI work without a magpie, launch a Debug build with `-perch-demo` (or the `PERCH_DEMO=1` environment variable). Every tab then fills with built-in demo data. `PERCH_DEMO_STATE` (`calm`, `empty`, `offline`, `loading`) and `PERCH_DEMO_HISTORY=unrecognized` switch to other states. The demo code is `#if DEBUG` only.

## Tests

### Unit tests (required for every PR)

```sh
xcodebuild test -project Perch.xcodeproj -scheme Perch \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skip-testing:PerchUITests
```

They need no network and no magpie. Add or update tests in `PerchTests/` for any change to decoding, formatting or store logic.

### End-to-end test (optional, about 15 minutes)

```sh
scripts/e2e.sh
```

The script downloads the latest `magpie-cli-darwin-arm64` release and starts a **throwaway** magpie under a temporary HOME. That magpie gets fake upstreams, routing groups and two fresh keys. The script then runs `PerchUITests` against it over the Mac's LAN address and checks on the magpie side that the routing changes landed. It never reads or changes your own magpie, and it never prints keys.

| Variable | Meaning | Default |
| --- | --- | --- |
| `PERCH_E2E_ARTIFACTS` | Output directory for the log, `.xcresult`, screenshots | `./build/e2e` |
| `PERCH_E2E_PORT` | Port for the throwaway `magpie serve` | `3430` |
| `PERCH_E2E_DESTINATION` | `xcodebuild -destination` | `platform=iOS Simulator,name=iPhone 17` |
| `MAGPIE_BIN` | Use this magpie binary instead of downloading one | latest release |
| `XCODEBUILD` | Test runner command | `xcodebuild` |

#### Against a magpie you run yourself

`PerchUITests` reads its target from the environment when there is no config file from `e2e.sh`. xcodebuild strips the `TEST_RUNNER_` prefix:

```sh
TEST_RUNNER_PERCH_E2E_ADDRESS='http://<your-mac>:3425' \
TEST_RUNNER_PERCH_E2E_KEY='<key with 可看额度 + 管理 API 任何电脑均可>' \
TEST_RUNNER_PERCH_E2E_VIEW_KEY='<key with 可看额度 only>' \
xcodebuild test -project Perch.xcodeproj -scheme Perch \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PerchUITests
```

Alternatively, point `PERCH_E2E_CONFIG` at a JSON file with `address`, `key` and `viewKey`. The UI tests **change routing groups** (they expect a `coder` group with `alpha/m-alpha`, `beta/m-beta`, `gamma/m-gamma`), so only use a magpie set up for testing. Never paste real addresses or keys into code, tests, issues or PRs.

## Code style

- Swift 6, SwiftUI, Observation. No third-party dependencies.
- Keep code comments in English. Use `///` doc comments on types and non-trivial functions. UI copy stays in Simplified Chinese, so comments may quote Chinese UI terms such as 额度, 路由组 or 密钥.
- User-facing strings go through `String(localized:)` / `LocalizedStringKey` (`Perch/Localizable.xcstrings`).
- Keep the networking tolerant: magpie's responses change between versions, so decoders skip what they can't read instead of failing.
- Respect Reduce Motion and Dynamic Type; use the helpers in `Perch/Design/`.

## Pull requests

1. Fork the repository and branch off `main`.
2. Keep PRs focused, and describe what changed and why. Include screenshots for UI changes; demo data (`-perch-demo`) is ideal.
3. Make sure the project builds and the unit tests pass.
4. Note the magpie version you tested against, if relevant.
5. Check your diff for personal data: no keys, addresses, team ids, bundle ids, emails or screenshots of real accounts.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
