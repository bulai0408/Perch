# Perch

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: iOS 26+](https://img.shields.io/badge/platform-iOS%2026%2B-lightgrey.svg)
![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)

**Perch 是 [magpie](https://github.com/yetone/magpie) 的 iPhone 遥控器。** 额度一眼看清，模型随手调。

[English](#english)

Perch 通过局域网（或你自己的 VPN / Tailscale 等）连到你电脑上运行的 magpie 网关，用 magpie 的密钥读取数据，让你在手机上：

- **额度**：看每个订阅账号（Claude、Kimi……）各窗口还剩多少、什么时候重置，以及照现在的速度大约什么时候用完；停用 / 启用账号。
- **Agent**：看 Claude Code、Codex、OpenCode 等 Agent 今天 / 7 天 / 30 天的调用次数、token、估算费用、失败原因，以及正在进行的调用。
- **路由组**：查看并修改 magpie 的路由组：调整顺序、设首选、切换路由方式。
- **多台电脑**：保存多台运行 magpie 的电脑，随时切换。

> Perch 是独立的社区项目，和 magpie 官方无关。

<p align="center">
  <img src="docs/screenshots/quotas.png" width="260" alt="额度">
  <img src="docs/screenshots/agent.png" width="260" alt="Agent">
  <img src="docs/screenshots/routing.png" width="260" alt="路由组">
</p>

截图中的账号、邮箱和数据都是 Debug 版本内置的演示数据（`-perch-demo`），不是真实账号。

## 版本要求

| 组件 | 要求 |
| --- | --- |
| iOS | 26.0 及以上（iPhone） |
| Xcode | 26 及以上（Swift 6） |
| magpie | 需要带路由组管理 API 的版本，开发时最早用的是 0.1.4260；0.1.4283 起 magpie 会告诉 Perch 自己的版本，Perch 才能显示版本和新版本提示 |

开发时曾在 magpie 0.1.4260、0.1.4266、0.1.4283（macOS）上测试过，这不是兼容承诺。更旧或更新的版本可能能看额度，但用量、路由组等功能可能读不到（magpie 返回 404 时 Perch 会显示错误）。

## 自己构建和签名

Perch 不在 App Store 上架，需要你用自己的 Apple 开发者账号构建（免费的 Personal Team 也可以装到自己的手机上）。

1. 克隆仓库：

   ```sh
   git clone https://github.com/bulai0408/Perch.git
   cd Perch
   ```

2. 复制本地签名配置（这个文件已被 gitignore，不会被提交）：

   ```sh
   cp Config/Local.example.xcconfig Config/Local.xcconfig
   ```

   然后编辑 `Config/Local.xcconfig`：

   ```
   PERCH_BUNDLE_ID = com.yourname.perch   // 一个属于你的 bundle id
   DEVELOPMENT_TEAM = YOURTEAMID          // 你的 Team ID（Xcode → Settings → Accounts）
   ```

   不创建这个文件也能编译到模拟器（使用占位的 `com.example.perch`），但装到真机必须填写。

3. 用 Xcode 打开 `Perch.xcodeproj`，选择 `Perch` scheme 和你的 iPhone，运行即可。也可以用命令行：

   ```sh
   xcodebuild -project Perch.xcodeproj -scheme Perch \
     -destination 'platform=iOS Simulator,name=iPhone 17' build
   ```

签名相关的所有设置都在 `Config/Perch.xcconfig`（提交到仓库，只有占位值）和 `Config/Local.xcconfig`（你自己的，不提交）里，`project.pbxproj` 里不含任何个人信息。

## 连接你自己的 magpie

1. **让 magpie 在局域网可访问**：在电脑上的 magpie 里打开「设置 → 网络与共享 → 在局域网共享」。magpie 默认端口是 `3425`。
2. **新建一把密钥**（`sk-magpie-…`），打开「可看额度」。
3. **（可选）允许改路由组**：在这把密钥那一行的菜单 → 高级 → 管理 API，选「任何电脑均可」。不开也能连上和看额度，只是不能修改路由组。
4. 在 Perch 里填入电脑的地址（例如 `http://192.168.1.20:3425`、`http://my-mac.local:3425`，或你的 VPN 地址；不写端口时默认 3425）和密钥，点「连接」。

说明：

- 密钥只保存在手机的钥匙串（Keychain）里，界面上永远只显示最后 4 位。
- magpie 在局域网上使用 HTTP，因此 `Config/Info.plist` 开启了 `NSAllowsArbitraryLoads` 和 `NSAllowsLocalNetworking`。第一次连接时 iOS 会请求「本地网络」权限，需要允许。
- 请只在可信的网络（家庭 / 办公局域网、VPN）里使用。不要把 magpie 端口直接暴露到公网。

## 开发与测试

- 单元测试（不需要 magpie）：

  ```sh
  xcodebuild test -project Perch.xcodeproj -scheme Perch \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skip-testing:PerchUITests
  ```

- 端到端测试 `scripts/e2e.sh`：在 Mac 上下载最新的 magpie CLI，在临时 HOME 里启动一个一次性的 magpie 和几个假的上游，再跑 `PerchUITests`。它**不会**读取或修改你自己的 magpie。需要 Apple silicon Mac、Xcode 和 iOS 模拟器，大约 15 分钟。可用的环境变量：

  | 变量 | 作用 | 默认值 |
  | --- | --- | --- |
  | `PERCH_E2E_ARTIFACTS` | 日志、`.xcresult`、截图的输出目录 | `./build/e2e` |
  | `PERCH_E2E_PORT` | 一次性 magpie 的端口 | `3430` |
  | `PERCH_E2E_DESTINATION` | `xcodebuild -destination` | `platform=iOS Simulator,name=iPhone 17` |
  | `MAGPIE_BIN` | 使用本地的 magpie 可执行文件，而不是下载 | 下载最新 release |
  | `XCODEBUILD` | 测试命令 | `xcodebuild` |

- 想让 UI 测试连**你自己的** magpie，可以不用脚本，直接给 `xcodebuild test` 传环境变量（`TEST_RUNNER_` 前缀会被 xcodebuild 去掉后传给测试）：
  `TEST_RUNNER_PERCH_E2E_ADDRESS`、`TEST_RUNNER_PERCH_E2E_KEY`（可看额度 + 管理 API）、`TEST_RUNNER_PERCH_E2E_VIEW_KEY`（只可看额度）。注意：UI 测试会**修改**路由组 `coder`，请只对测试用的 magpie 这样做。
- Debug 版本支持 `-perch-demo` 启动参数（或环境变量 `PERCH_DEMO=1`），用内置的演示数据填满所有页面，方便截图和开发 UI，不需要 magpie。Release 版本不包含这些代码。

详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 参与贡献

欢迎提 Issue 和 Pull Request，请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [行为准则](CODE_OF_CONDUCT.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要公开提 Issue。

## 许可证

[MIT](LICENSE) © 2026 Perch contributors

---

## English

**Perch is an iPhone remote for [magpie](https://github.com/yetone/magpie).** Check your quotas at a glance and switch models on the go.

Perch connects to the magpie gateway running on your computer, over your LAN or your own VPN, and authenticates with a magpie gateway key. It lets you:

- **Quotas (额度)**: see what's left in each subscription account's windows, when they reset and when they'll run out at the current pace. You can also switch accounts on or off.
- **Agent**: see calls, tokens, estimated cost, failures and live calls per agent (Claude Code, Codex, OpenCode…) for today, 7 days or 30 days.
- **Routing groups (路由组)**: view and change magpie's routing groups: reorder members, set the first choice, change the routing mode.
- **Several computers**: save more than one magpie computer and switch between them.

The UI is in Simplified Chinese. Perch is an independent community project, not affiliated with magpie. The accounts in the screenshots are built-in demo data (`-perch-demo`).

### Requirements

- iOS 26.0+ (iPhone), Xcode 26+ (Swift 6).
- A magpie build with the routing-group admin API; the earliest version used during development was 0.1.4260. From 0.1.4283 magpie reports its version, which Perch needs to show the version and update hints.
- During development Perch was tested against magpie 0.1.4260, 0.1.4266 and 0.1.4283 on macOS. This is not a compatibility promise.

### Build and sign it yourself

Perch isn't on the App Store, so you build it with your own Apple developer account. A free Personal Team works.

```sh
git clone https://github.com/bulai0408/Perch.git
cd Perch
cp Config/Local.example.xcconfig Config/Local.xcconfig   # gitignored
```

Set `PERCH_BUNDLE_ID` (a bundle id you own) and `DEVELOPMENT_TEAM` (your team id) in `Config/Local.xcconfig`. Then open `Perch.xcodeproj`, pick the `Perch` scheme and your iPhone, and run.

Simulator builds work without `Local.xcconfig`, using the placeholder `com.example.perch`. No personal signing values live in the project file. `Config/Perch.xcconfig` holds the placeholders and includes your optional `Local.xcconfig`.

### Connect your own magpie

1. In magpie on your computer, turn on **Settings → Network & sharing → Share on LAN**. The default port is `3425`.
2. Create a gateway key (`sk-magpie-…`) and enable **View quotas (可看额度)**.
3. Optional, to change routing groups: in that key's menu → Advanced → **Admin API**, choose **Any computer (任何电脑均可)**.
4. In Perch, enter the address and the key, then tap Connect. Examples: `http://192.168.1.20:3425`, `http://my-mac.local:3425`, or a VPN address; the port defaults to 3425.

The key is stored only in the iOS Keychain and is never shown in full. magpie serves plain HTTP on the LAN, so `Config/Info.plist` allows arbitrary loads and local networking, and iOS asks for Local Network access on first connect. Use Perch only on networks you trust. Don't expose magpie's port to the internet.

### Development and tests

- Unit tests (no magpie needed): `xcodebuild test -project Perch.xcodeproj -scheme Perch -destination 'platform=iOS Simulator,name=iPhone 17' -skip-testing:PerchUITests`
- `scripts/e2e.sh` is the end-to-end test, taking about 15 minutes. It downloads the latest magpie CLI and runs a **throwaway** magpie with fake upstreams under a temporary HOME. Then it runs `PerchUITests` against it. It never touches your own magpie. It is configured through the `PERCH_E2E_ARTIFACTS`, `PERCH_E2E_PORT`, `PERCH_E2E_DESTINATION`, `MAGPIE_BIN` and `XCODEBUILD` environment variables (table above).
- To run the UI tests against a magpie of your own, pass `TEST_RUNNER_PERCH_E2E_ADDRESS`, `TEST_RUNNER_PERCH_E2E_KEY` (quotas + admin API) and `TEST_RUNNER_PERCH_E2E_VIEW_KEY` (quotas only) to `xcodebuild test`. Do this only with a test magpie: the tests **change** the `coder` routing group.
- Debug builds accept `-perch-demo` (or `PERCH_DEMO=1`), which fills every tab with built-in demo data with no magpie needed. That code is compiled out of Release builds.

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

### License

[MIT](LICENSE) © 2026 Perch contributors
