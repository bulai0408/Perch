## What and why / 改了什么、为什么

<!-- A short description. Link the issue: "Fixes #123". -->

## How it was tested / 怎么测的

- [ ] Builds in Xcode (Simulator) / 能编译
- [ ] Unit tests pass (`-skip-testing:PerchUITests`) / 单元测试通过
- [ ] Tried on a device or Simulator against magpie version: <!-- e.g. 0.1.4283 -->
- [ ] `scripts/e2e.sh` (optional, for connect / routing changes)

## Screenshots / 截图

<!-- For UI changes. Prefer demo data (`-perch-demo`). -->

## Checklist / 检查

- [ ] No keys, addresses, emails, team ids or bundle ids in the diff / 没有提交密钥、地址、邮箱、Team ID、bundle id
- [ ] `Config/Local.xcconfig` is not committed / 没有提交 `Config/Local.xcconfig`
- [ ] New types and non-trivial functions have `///` doc comments (English) / 新代码有英文文档注释
- [ ] User-facing text uses `String(localized:)` / 界面文字可本地化
