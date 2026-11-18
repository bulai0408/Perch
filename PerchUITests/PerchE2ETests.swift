import XCTest

/// End to end against a real magpie that scripts/e2e.sh starts on the
/// Mac (the magpie darwin-arm64 CLI, `magpie serve` on 0.0.0.0:3430,
/// reached over the Mac's LAN address like a phone; routing groups
/// 「Coder」 alpha, beta, gamma 按顺序 and 「Pinned」 alpha, beta 手动 on alpha).
/// Nothing here is mocked: every screen reads and changes that magpie.
final class PerchE2ETests: XCTestCase {
    /// The magpie under test, from `PERCH_E2E_CONFIG` (JSON) or the
    /// `PERCH_E2E_ADDRESS` / `PERCH_E2E_KEY` / `PERCH_E2E_VIEW_KEY` variables.
    struct Config: Decodable {
        var address: String
        /// 「可看额度」 + 管理 API 「任何电脑均可」.
        var key: String
        /// 「可看额度」 only.
        var viewKey: String
        var group: String
        /// The model made 首选: `beta/m-beta`.
        var member: String
        var memberTitle: String
        /// Whether `address` is the LAN one. On loopback magpie takes any
        /// key for 额度, so the wrong-key test can't run there.
        var lan: Bool? = nil
        /// 1.4: e2e.sh made Claude Code calls that failed (429), that magpie
        /// handed on (500 → alpha), and keeps one slow call running.
        var agentCalls: Bool? = nil
        /// A group e2e.sh switched off (`retired`), and those it deleted:
        /// one of the user's, gone from magpie's list, and a found one
        /// magpie keeps with `"hidden": true`.
        var disabledGroup: String? = nil
        var deletedGroups: [String]? = nil
    }

    private var config: Config!

    override func setUpWithError() throws {
        continueAfterFailure = false
        config = try Self.loadConfig()
    }

    /// e2e.sh hands the values over as TEST_RUNNER_ environment variables
    /// (xcodebuild strips the prefix) and in a file, whichever arrives.
    static func loadConfig() throws -> Config {
        let env = ProcessInfo.processInfo.environment
        var paths = ["/tmp/perch-e2e/config.json"]
        if let p = env["PERCH_E2E_CONFIG"] { paths.insert(p, at: 0) }
        for path in paths {
            if let data = FileManager.default.contents(atPath: path),
               let config = try? JSONDecoder().decode(Config.self, from: data) {
                return config
            }
        }
        if let address = env["PERCH_E2E_ADDRESS"], let key = env["PERCH_E2E_KEY"], let view = env["PERCH_E2E_VIEW_KEY"] {
            return Config(address: address, key: key, viewKey: view, group: "coder",
                          member: "beta/m-beta", memberTitle: "m-beta")
        }
        XCTFail("No e2e config: run scripts/e2e.sh, which starts magpie and writes it")
        throw XCTSkip("no config")
    }

    /// Launches the app with nothing saved, in Chinese.
    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-perch-reset", "-perch-long-toasts", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    /// Taps a field and types into it.
    private func type(_ text: String, into element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing \(element)")
        element.tap()
        element.typeText(text)
    }

    /// Attaches a named screenshot to the result.
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Fills the connect screen with the configured address and `key`, then connects.
    private func connect(_ app: XCUIApplication, key: String, shotName: String? = nil) {
        XCTAssertTrue(any(app, "connect-title").waitForExistence(timeout: 15))
        type(config.address, into: app.textFields["address-field"])
        type(key, into: app.secureTextFields["key-field"])
        if let shotName { shot(app, shotName) }
        app.buttons["connect-button"].tap()
    }

    /// System prompts that can sit over Perch after connecting: 本地网络
    /// (Perch talks to the LAN address) and 存储密码 (the 密钥 field).
    private func dismissSystemPrompts(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let answers = ["允许", "Allow", "不是现在", "Not Now", "以后", "好"]
        for owner in [springboard, app] {
            for answer in answers {
                let button = owner.buttons[answer].firstMatch
                if button.exists && button.isHittable {
                    button.tap()
                    return
                }
            }
        }
    }

    /// iOS 27's tab bar shows each tab as two buttons, and only one of them
    /// switches: try each until the tab's navigation bar shows.
    /// `ready`: what shows once the tab is open, when it isn't a navigation
    /// bar named after the tab (the Agent tab draws its own title).
    private func openTab(_ app: XCUIApplication, _ name: String, ready: XCUIElement? = nil) {
        let bar = ready ?? app.navigationBars[name]
        let buttons = app.tabBars.buttons.matching(NSPredicate(format: "label == %@", name))
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 10), "no \(name) tab")
        for attempt in 0..<3 {
            dismissSystemPrompts(app)
            for i in 0..<max(buttons.count, 1) {
                let button = buttons.element(boundBy: i)
                guard button.exists, button.isHittable else { continue }
                button.tap()
                if bar.waitForExistence(timeout: 4) { return }
            }
            if attempt < 2 { sleep(2) }
        }
        if bar.exists { return }
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "tab-\(name)-failed-screen"
        screen.lifetime = .keepAlways
        add(screen)
        print("== springboard ==\n\(XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)")
        print("== app ==\n\(app.debugDescription)")
        XCTFail("tab \(name) did not open")
    }

    /// The visible 「设为首选」 button on the member's row (1.2).
    private func makePrimary(_ app: XCUIApplication, _ memberID: String) {
        let button = app.buttons["make-primary-\(memberID)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no 设为首选 on \(memberID)")
        XCTAssertEqual(button.label, "设为首选")
        button.tap()
    }

    /// 选用方式 is a Menu (1.2): open it, then pick the item.
    private func chooseMode(_ app: XCUIApplication, raw: String, label: String, shotName: String? = nil) {
        app.buttons["routing-mode"].tap()
        var item = any(app, "mode-\(raw)")
        if !item.waitForExistence(timeout: 5) {
            item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(label) in the 选用方式 menu")
        XCTAssertTrue(app.staticTexts["常用"].exists || app.otherElements["常用"].exists || any(app, "常用").exists, "no 常用 section")
        if let shotName { shot(app, shotName) }
        item.tap()
        // A tap while the menu is still animating open can be dropped.
        if item.waitForNonExistence(timeout: 2) == false, item.exists, item.isHittable {
            item.tap()
        }
    }

    /// The group screen has an inline title (name over 「共 N 个模型」).
    private func waitForGroup(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(any(app, "group-detail").waitForExistence(timeout: 10), "\(name) did not open")
        XCTAssertTrue(app.navigationBars.staticTexts[name].firstMatch.waitForExistence(timeout: 5)
                      || app.navigationBars[name].exists, "no \(name) title")
    }

    /// The first element of any type with this identifier.
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Waits for a toast containing `text`, screenshots it, waits for it to go.
    private func expectToast(_ app: XCUIApplication, _ text: String, _ name: String) {
        let toast = app.staticTexts["toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "no toast for \(text)")
        XCTAssertTrue(toast.label.contains(text), toast.label)
        shot(app, name)
        _ = toast.waitForNonExistence(timeout: 12)
    }

    /// Launches with the DEBUG demo data and extra environment.
    private func launchDemo(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-perch-reset", "-perch-long-toasts", "-perch-demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
        return app
    }

    /// The 额度 cards on screen.
    private func cards(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "quota-card")
    }

    /// Debug-only `-perch-demo` data (1.3): 额度 grouped by provider, sort,
    /// card menu. No magpie needed; the hook is compiled out of Release.
    func test0_quotaLayoutWithDemoCards() throws {
        let app = launchDemo()
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20))
        // 1.5: the hero replaces the three tiles; 账号 N · 1 个已停用 moves to the section header.
        let hero = any(app, "quota-hero")
        XCTAssertTrue(hero.waitForExistence(timeout: 10))
        XCTAssertTrue(hero.label.hasPrefix("现在最紧："), hero.label)
        XCTAssertTrue(hero.label.contains("剩 7%"), hero.label)
        XCTAssertTrue(["41 分钟", "42 分钟", "43 分钟"].contains { hero.label.contains($0) }, hero.label)
        let count = "\(any(app, "quota-section-count-claude").label)"
        XCTAssertTrue(count.contains("1 个已停用"), count)
        XCTAssertTrue(any(app, "status-capsule").exists, "no status capsule")
        // 用得多的在前 is the default, and Claude (most calls) is the first group.
        XCTAssertEqual("\(any(app, "quota-sort").value ?? "")", "用得多的在前")
        XCTAssertTrue(any(app, "quota-section-claude").exists, "no Claude group")
        let first = cards(app).firstMatch
        XCTAssertTrue(first.label.hasPrefix("工作号"), first.label)
        XCTAssertTrue(first.label.contains("刚刚在用"), first.label)
        XCTAssertTrue(first.label.contains("Opus 每周"), first.label)
        shot(app, "20-quotas")

        any(app, "quota-sort").tap()
        let bySoonest = app.buttons["快重置的在前"].firstMatch
        XCTAssertTrue(bySoonest.waitForExistence(timeout: 5))
        shot(app, "20b-quotas-sort-menu")
        pickSort(app, bySoonest, expect: "快重置的在前")
        // Inside the Claude group, 个人号 (42 分) now comes first.
        XCTAssertTrue(cards(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual("\(any(app, "quota-sort").value ?? "")", "快重置的在前")
        XCTAssertTrue(cards(app).firstMatch.label.hasPrefix("个人号"), cards(app).firstMatch.label)

        let card = cards(app).firstMatch
        let refresh = app.buttons["刷新这张额度"].firstMatch
        // A long-press right after the re-sort animation can be dropped: retry.
        func openMenu() {
            for _ in 0..<3 {
                sleep(1)
                card.press(forDuration: 1.2)
                if refresh.waitForExistence(timeout: 4) { return }
            }
            XCTFail("no 刷新这张额度 on long-press")
        }
        openMenu()
        refresh.tap()
        sleep(1)
        openMenu()
        refresh.tap()
        expectToast(app, "刚刷新过", "20c-quotas-cooldown")

        // Back to the default for the next run.
        any(app, "quota-sort").tap()
        let byMostUsed = app.buttons["用得多的在前"].firstMatch
        XCTAssertTrue(byMostUsed.waitForExistence(timeout: 5))
        pickSort(app, byMostUsed, expect: "用得多的在前")
        XCTAssertEqual("\(any(app, "quota-sort").value ?? "")", "用得多的在前")
        XCTAssertTrue(cards(app).firstMatch.label.hasPrefix("工作号"), cards(app).firstMatch.label)
    }

    /// Taps a sort-menu item once the menu has finished animating in, then
    /// waits for the sort control to report the new order.
    /// The simulator sometimes drops a tap on a menu item that is still
    /// settling (the menu stays or closes, the choice doesn't take), so a
    /// missed pick reopens the menu and tries again, up to three times.
    private func pickSort(_ app: XCUIApplication, _ item: XCUIElement, expect: String) {
        let control = any(app, "quota-sort")
        let isSorted = NSPredicate(format: "value == %@", expect)
        for attempt in 1...3 {
            if attempt > 1 {
                if !item.exists { control.tap() }
                _ = item.waitForExistence(timeout: 5)
            }
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: item)
            _ = XCTWaiter.wait(for: [hittable], timeout: 5)
            usleep(400_000)
            item.tap()
            let sorted = XCTNSPredicateExpectation(predicate: isSorted, object: control)
            if XCTWaiter.wait(for: [sorted], timeout: 5) == .completed { return }
        }
        XCTFail("sort: \(expect) didn't take after 3 picks; value is \(control.value ?? "nil")")
    }

    /// 1.3 screens on demo data: account detail, the Agent tab and its
    /// menu, 全部 calls, one call, and 路由组 with 「Claude Code 刚刚在用」.
    func test0b_agentScreensWithDemoData() throws {
        let app = launchDemo()
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20))

        // 账号详情: windows, today's calls, 在 Agent 页看.
        let work = cards(app).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        work.tap()
        XCTAssertTrue(app.staticTexts["额度是怎么用掉的"].waitForExistence(timeout: 10), "account detail did not open")
        // 1.5: the zoom transition settles the nav bar a moment later.
        XCTAssertTrue(app.navigationBars["工作号"].waitForExistence(timeout: 5) || app.staticTexts["工作号"].exists, "no 工作号 title")
        XCTAssertTrue(any(app, "history-caption").exists || app.staticTexts["周四 08:00 起，用掉了 41%"].exists)
        sleep(1)
        shot(app, "21-account-detail")
        app.swipeUp()
        let openAgent = any(app, "account-open-agent")
        XCTAssertTrue(openAgent.waitForExistence(timeout: 5), "no 在 Agent 页看")
        XCTAssertTrue(any(app, "account-toggle").exists, "no 停用 switch")
        shot(app, "21b-account-detail-bottom")

        // Agent tab: Claude Code by default.
        openTab(app, "Agent", ready: any(app, "agent-title-menu"))
        XCTAssertTrue(any(app, "agent-tile-calls").waitForExistence(timeout: 10))
        let calls = any(app, "agent-tile-calls")
        let callsText = "\(calls.label) \(calls.value ?? "")"
        XCTAssertTrue(callsText.contains("184"), callsText)
        XCTAssertTrue(any(app, "agent-account-row").exists, "no 按账号 rows")
        sleep(1)
        shot(app, "22-agent")

        // 换个 Agent: the title menu, most calls first, then 所有 Agent.
        let title = any(app, "agent-title-menu")
        XCTAssertTrue(title.label.contains("Claude Code"), title.label)
        title.tap()
        // Menu items, not the title button (also labelled Claude Code).
        func item(_ id: String, _ prefix: String) -> XCUIElement {
            let byID = app.buttons["agent-menu-\(id)"].firstMatch
            if byID.waitForExistence(timeout: 3) { return byID }
            return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier != 'agent-title-menu'", prefix)).firstMatch
        }
        let claudeItem = item("claude", "Claude Code")
        XCTAssertTrue(claudeItem.waitForExistence(timeout: 5), "no agent menu")
        let all = app.buttons["所有 Agent"].firstMatch
        XCTAssertTrue(all.exists, "no 所有 Agent")
        let codex = item("codex", "Codex")
        XCTAssertTrue(codex.exists, "no Codex in the menu")
        XCTAssertLessThan(claudeItem.frame.minY, codex.frame.minY, "Claude Code (most calls) is not first")
        XCTAssertLessThan(codex.frame.minY, all.frame.minY, "所有 Agent is not last")
        shot(app, "23-agent-menu")
        claudeItem.tap()

        // 全部 calls, then one call.
        app.swipeUp()
        let allCalls = any(app, "agent-all-calls")
        XCTAssertTrue(allCalls.waitForExistence(timeout: 5))
        allCalls.tap()
        XCTAssertTrue(app.navigationBars["最近的调用"].waitForExistence(timeout: 10)
                      || app.navigationBars.staticTexts["最近的调用"].firstMatch.waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any).matching(identifier: "all-call-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no rows in 全部")
        shot(app, "24-all-calls")
        row.tap()
        XCTAssertTrue(app.navigationBars["一次调用"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["magpie 不记录对话内容，这里只有这些数字。"].waitForExistence(timeout: 5)
                      || { app.swipeUp(); return app.staticTexts["magpie 不记录对话内容，这里只有这些数字。"].exists }())
        shot(app, "25-call-detail")

        // 路由组: 「Claude Code 刚刚在用」 on top, pointing at coder.
        openTab(app, "路由组")
        let header = any(app, "agent-target-header")
        XCTAssertTrue(header.waitForExistence(timeout: 10), "no 刚刚在用 block")
        XCTAssertTrue(header.label.contains("Claude Code 刚刚在用"), header.label)
        let target = any(app, "agent-target-group")
        XCTAssertTrue(target.exists, "刚刚在用 is not a group")
        XCTAssertTrue(target.label.lowercased().contains("coder"), target.label)
        shot(app, "26-routes-top")
    }

    /// 1.5b on demo data: the hero's horizon dot is bad whenever the
    /// sky is tight (here a run-out line on 工作号's card while the hero is
    /// 21 % left), the history chart (demo history goes through the real
    /// decoder, in the latest magpie's `lines`/`left` shape), and the
    /// unrecognised-history state under the error art.
    func test0d_v15bHeroAndHistoryStates() throws {
        let app = launchDemo(["PERCH_DEMO_STATE": "calm"])
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20))
        let hero = any(app, "quota-hero")
        XCTAssertTrue(hero.waitForExistence(timeout: 10))
        XCTAssertTrue(hero.label.contains("剩 21%"), hero.label)
        XCTAssertTrue(any(app, "quota-card").label.contains("用完") || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "用完")).firstMatch.exists,
                      "no run-out line on the cards")
        sleep(2)
        shot(app, "30-hero-tight-red-dot")

        let work = cards(app).firstMatch
        XCTAssertTrue(work.label.hasPrefix("工作号"), work.label)
        work.tap()
        XCTAssertTrue(app.staticTexts["额度是怎么用掉的"].waitForExistence(timeout: 10), "account detail did not open")
        XCTAssertTrue(any(app, "history-caption").waitForExistence(timeout: 5), "no history chart")
        XCTAssertFalse(any(app, "history-unrecognized").exists, "history shown as unreadable")
        XCTAssertFalse(app.staticTexts["还没有记录。magpie 会边用边记，过一阵再来看。"].exists, "history shown as empty")
        app.swipeUp()
        sleep(2)
        shot(app, "31-history-chart")
        app.terminate()

        let odd = launchDemo(["PERCH_DEMO_HISTORY": "unrecognized"])
        XCTAssertTrue(odd.navigationBars["额度"].waitForExistence(timeout: 20))
        XCTAssertTrue(cards(odd).firstMatch.waitForExistence(timeout: 10))
        cards(odd).firstMatch.tap()
        XCTAssertTrue(odd.staticTexts["额度是怎么用掉的"].waitForExistence(timeout: 10))
        let note = odd.staticTexts["这版 magpie 的数据 Perch 还读不懂，先不显示这一块。别的照常能看。"]
        XCTAssertTrue(note.waitForExistence(timeout: 5) || any(odd, "history-unrecognized").exists, "no unrecognized state")
        // Bring the art and the line fully on screen (above the tab bar) for
        // the shot, in small drags so it doesn't scroll past them.
        let state = any(odd, "history-unrecognized")
        let bottom = odd.windows.firstMatch.frame.maxY - 110
        for _ in 0..<6 where state.exists && state.frame.maxY > bottom {
            let from = odd.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -200)))
        }
        XCTAssertTrue(state.frame.maxY <= bottom, "unrecognized state not fully on screen")
        XCTAssertFalse(any(odd, "history-caption").exists)
        sleep(2)
        shot(odd, "32-history-unrecognized")
    }

    /// Demo data: the Agent empty state, 设为首选 moving the
    /// row to the top with the 首选 chip, and 设置 关于 with the credit.
    func test0e_v15Stage2AgentRoutingAbout() throws {
        let empty = launchDemo(["PERCH_DEMO_STATE": "empty"])
        XCTAssertTrue(empty.navigationBars["额度"].waitForExistence(timeout: 20))
        openTab(empty, "Agent", ready: any(empty, "agent-period"))
        XCTAssertTrue(any(empty, "agent-empty").waitForExistence(timeout: 10), "no Agent empty state")
        XCTAssertTrue(empty.staticTexts["还没有 Agent 来过"].exists, "no 还没有 Agent 来过")
        XCTAssertFalse(any(empty, "agent-live").exists, "正在进行 with no calls")
        shot(empty, "50-agent-empty")
        empty.terminate()

        let app = launchDemo()
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20))
        openTab(app, "Agent", ready: any(app, "agent-title-menu"))
        XCTAssertTrue(any(app, "agent-tile-calls").waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "period-today").isSelected, "今天 is not the default")
        any(app, "period-7d").tap()
        XCTAssertTrue(any(app, "period-7d").isSelected, "7 天 not selected")
        XCTAssertTrue(any(app, "agent-summary").waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "agent-summary").label.hasPrefix("这 7 天"), any(app, "agent-summary").label)
        shot(app, "51-agent-7d")
        any(app, "period-today").tap()

        // 设为首选 (demo: the group changes in place): gamma moves to the top.
        openTab(app, "路由组")
        let coder = app.buttons["group-coder"]
        XCTAssertTrue(coder.waitForExistence(timeout: 10))
        coder.tap()
        waitForGroup(app, "Coder")
        let alpha = any(app, "member-alpha/m-alpha")
        let gamma = any(app, "member-gamma/m-gamma")
        XCTAssertTrue(alpha.waitForExistence(timeout: 10) && gamma.exists)
        XCTAssertTrue(alpha.label.contains("首选"), alpha.label)
        XCTAssertLessThan(alpha.frame.minY, gamma.frame.minY)
        makePrimary(app, "gamma/m-gamma")
        expectToast(app, "已把 m-gamma 设为首选", "52-primary-demo")
        XCTAssertTrue(any(app, "member-gamma/m-gamma").label.contains("首选"), any(app, "member-gamma/m-gamma").label)
        XCTAssertFalse(any(app, "member-alpha/m-alpha").label.contains("首选"))
        XCTAssertLessThan(any(app, "member-gamma/m-gamma").frame.minY, any(app, "member-alpha/m-alpha").frame.minY,
                          "设为首选 did not move the row to the top")

        // 设置 → 关于: icon, Perch, the one-liner, the note, Made with AirBuild.
        openTab(app, "设置")
        let about = any(app, "about-header")
        for _ in 0..<6 where !(about.exists && about.isHittable) { app.swipeUp() }
        XCTAssertTrue(about.exists, "no 关于 header")
        XCTAssertTrue(about.label.contains("Perch") && about.label.contains("额度一眼看清，模型随手调。"), about.label)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Perch 是 magpie 的手机遥控器，和 magpie 官方无关。"].waitForExistence(timeout: 5)
                      || any(app, "about-note").exists, "no 关于 note")
        let credit = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "AirBuild")).firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: 5), "no Made with AirBuild")
        shot(app, "53-settings-about")
    }

    /// 1.4 on demo data: run-out, 登录已失效, the version banner and notes,
    /// the Agent summary, 正在进行, cost bars, failures in words, the call
    /// list chips, 「magpie 原话」, two computers and 「magpie 版本」.
    func test0c_v14ScreensWithDemoData() throws {
        let app = launchDemo()
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20))
        XCTAssertTrue(cards(app).firstMatch.waitForExistence(timeout: 10))

        // 额度: 登录已失效 on a card, the 新版本 banner.
        let expired = cards(app).matching(NSPredicate(format: "label CONTAINS %@", "登录已失效")).firstMatch
        XCTAssertTrue(expired.waitForExistence(timeout: 5), "no 登录已失效 card")
        let banner = any(app, "version-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no version banner")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "上的 magpie 有新版本")).firstMatch.exists,
                      "banner text")
        let runOutOnCard = any(app, "run-out").exists
        print("run-out line on 额度: \(runOutOnCard)")
        shot(app, "30-quotas-v14")

        any(app, "version-banner-notes").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "magpie ", " 改了什么")).firstMatch
                        .waitForExistence(timeout: 10)
                      || app.navigationBars.matching(NSPredicate(format: "identifier ENDSWITH %@", "改了什么")).firstMatch.exists,
                      "no release notes title")
        shot(app, "31-release-notes")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        any(app, "version-banner-close").tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5), "banner did not close")

        // Account detail of the 登录已失效 card: the note, no button.
        expired.tap()
        let note = any(app, "login-expired-note")
        XCTAssertTrue(note.waitForExistence(timeout: 10), "no 登录已失效 note")
        XCTAssertTrue(note.label.contains("在电脑上的 magpie 里重新登录就好"), note.label)
        shot(app, "32-account-login-expired")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 工作号: run-out line and 「怎么算的」 when the pace says so.
        let work = cards(app).matching(NSPredicate(format: "label BEGINSWITH %@", "工作号")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        work.tap()
        XCTAssertTrue(app.staticTexts["额度是怎么用掉的"].waitForExistence(timeout: 10))
        let how = any(app, "run-out-how")
        if how.waitForExistence(timeout: 3) || { app.swipeUp(); return how.waitForExistence(timeout: 3) }() {
            shot(app, "33-account-run-out")
            how.tap()
            XCTAssertTrue(app.staticTexts["按最近一小时的用法往后推，用法变了时间也会变，只供参考。"].waitForExistence(timeout: 5)
                          || any(app, "run-out-explain").waitForExistence(timeout: 2), "no 怎么算的 popover")
            shot(app, "33b-run-out-how")
            app.tap()
        } else {
            print("no run-out on 工作号 in the demo (pace lasts past the reset)")
            shot(app, "33-account-run-out")
        }

        // Agent: summary, 正在进行, 每小时的费用, token 缓存.
        openTab(app, "Agent", ready: any(app, "agent-title-menu"))
        let summary = any(app, "agent-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "no summary")
        XCTAssertTrue(summary.label.hasPrefix("今天 Claude Code 调用 184 次"), summary.label)
        let live = any(app, "agent-live")
        XCTAssertTrue(live.waitForExistence(timeout: 10), "no 正在进行 card")
        XCTAssertTrue(live.label.contains("正在进行") && live.label.contains("已经"), live.label)
        let tokens = any(app, "agent-tile-tokens")
        XCTAssertTrue("\(tokens.value ?? "")".contains("缓存"), "\(tokens.value ?? "")")
        XCTAssertTrue(app.staticTexts["每小时的费用"].exists, "no 每小时的费用")
        shot(app, "34-agent-v14")

        // 30 天: 每天的费用, tap a bar for the callout.
        // 1.5: a custom segmented control (track + sliding card).
        any(app, "period-30d").tap()
        XCTAssertTrue(any(app, "period-30d").isSelected, "30 天 not selected")
        XCTAssertTrue(app.staticTexts["每天的费用"].waitForExistence(timeout: 10), "no 每天的费用")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "agent-summary").label.hasPrefix("这 30 天 Claude Code 调用"), any(app, "agent-summary").label)
        let chart = any(app, "agent-chart")
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7)).tap()
        let callout = any(app, "agent-chart-callout")
        if callout.waitForExistence(timeout: 3) {
            XCTAssertTrue(callout.label.contains("约 $"), callout.label)
        }
        shot(app, "35-agent-30d")
        any(app, "period-today").tap()

        // 「失败 N 次。」 → 最近的调用 on 只看失败, rows in words.
        let failures = any(app, "agent-summary-failures")
        XCTAssertTrue(failures.waitForExistence(timeout: 10), "no 失败 N 次")
        failures.tap()
        let failedRow = app.descendants(matching: .any).matching(identifier: "all-call-row").firstMatch
        XCTAssertTrue(failedRow.waitForExistence(timeout: 10), "no failed rows")
        XCTAssertTrue(any(app, "chip-failed").isSelected || any(app, "chip-failed").exists)
        let human = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                                         "额度用完了", "被限流了", "找不到模型", "那边出错了")).firstMatch
        XCTAssertTrue(human.waitForExistence(timeout: 5), "no human failure line")
        shot(app, "36-calls-failed")
        failedRow.tap()
        let original = any(app, "call-original")
        XCTAssertTrue(original.waitForExistence(timeout: 10), "no magpie 原话")
        XCTAssertTrue(original.label.hasPrefix("magpie 原话："), original.label)
        shot(app, "37-call-failed-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 换过账号的: 「换到了 …」 at the row's end, no 失败 chip.
        let switchedChip = any(app, "chip-switched")
        XCTAssertTrue(switchedChip.waitForExistence(timeout: 5))
        switchedChip.tap()
        let switched = any(app, "call-switched")
        XCTAssertTrue(switched.waitForExistence(timeout: 10), "no 换到了 rows")
        XCTAssertTrue(switched.label.contains("换到了 "), switched.label)
        shot(app, "38-calls-switched")

        // Two computers: the capsule menu and Settings 「电脑」, 「magpie 版本」.
        openTab(app, "设置")
        XCTAssertTrue(any(app, "computer-row-家里").waitForExistence(timeout: 10), "no 家里 row")
        XCTAssertTrue(any(app, "settings-add-computer").exists, "no 添加")
        let version = any(app, "settings-magpie-version")
        if !version.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(version.waitForExistence(timeout: 5), "no magpie 版本 row")
        XCTAssertTrue(version.label.contains("magpie 版本"), version.label)
        XCTAssertTrue(version.label.contains("有新版本") || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "有新版本")).firstMatch.exists,
                      version.label)
        shot(app, "39-settings-v14")
        openTab(app, "额度")
        any(app, "status-capsule").tap()
        XCTAssertTrue(any(app, "add-computer-menu").waitForExistence(timeout: 5), "no 添加电脑…")
        shot(app, "40-computer-menu")
        let home = menuItem(app, "家里")
        XCTAssertTrue(home.waitForExistence(timeout: 5), "no 家里 in the menu")
        home.tap()
        expectToast(app, "已换到 家里", "41-switched-computer")
    }

    func test1_wrongKeyIsRefusedWithTheCopyLine() throws {
        guard config.lan == true else {
            throw XCTSkip("magpie is only on loopback here, where it takes any key for 额度")
        }
        let app = launchFresh()
        connect(app, key: "sk-magpie-this-key-is-wrong-0000")
        let error = any(app, "quota-error")
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("密钥对不上。回电脑上的 magpie 再复制一次。"), error.label)
        shot(app, "01-connect-wrong-key")
    }

    /// A key without 管理 API 「任何电脑均可」 still connects; 路由组 explains.
    func test2_keyWithoutAdminConnectsAndExplains() throws {
        let app = launchFresh()
        connect(app, key: config.viewKey)
        let note = any(app, "quota-note")
        XCTAssertTrue(note.waitForExistence(timeout: 15), "no 已连上，可以看额度 note")
        XCTAssertTrue(note.label.contains("已连上，可以看额度"), note.label)
        shot(app, "02-connect-noadmin")

        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20), "did not reach the tabs")
        openTab(app, "路由组")
        // 1.5: the art state, no retry button.
        XCTAssertTrue(any(app, "routing-noadmin").waitForExistence(timeout: 20), "no 这把密钥只能看额度 state")
        XCTAssertTrue(app.staticTexts["这把密钥只能看额度"].exists)
        XCTAssertFalse(app.buttons["group-\(config.group)"].exists, "list shown without admin")
        shot(app, "03-routes-noadmin")

        // 设置: 「这把密钥能」 shows 改路由组 · 未打开, which explains on tap.
        openTab(app, "设置")
        let routing = any(app, "permission-routing")
        XCTAssertTrue(routing.waitForExistence(timeout: 10))
        XCTAssertTrue(routing.label.contains("改路由组 · 未打开"), routing.label)
        XCTAssertTrue(any(app, "permission-quotas").label.contains("✓ 看额度"), any(app, "permission-quotas").label)
        // iOS may offer 「Save Password?」 for the key a moment after connecting.
        for _ in 0..<10 where !routing.isHittable {
            dismissSystemPrompts(app)
            sleep(1)
        }
        routing.tap()
        let help = app.staticTexts["这把密钥不能改路由组。在电脑的 magpie 里，这把密钥那一行点 ⋯ →「高级」→「管理 API」，选「任何电脑均可」。"]
        XCTAssertTrue(help.waitForExistence(timeout: 5), "no 403 line on tap")
        shot(app, "03b-settings-noadmin")
    }

    func test3_connectReadQuotasAndChangeRoutingGroup() throws {
        let app = launchFresh()
        connect(app, key: config.key, shotName: "04-connect-filled")

        // 额度: the real magpie has no accounts (MAGPIE_NO_ACCOUNTS), so its
        // cards list is empty and Perch shows the empty state.
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20), "did not reach the tabs")
        XCTAssertTrue(app.staticTexts["还没有额度可看"].waitForExistence(timeout: 15))
        // 1.3: the Agent tab is always there.
        XCTAssertTrue(app.tabBars.buttons["Agent"].firstMatch.exists, "no Agent tab")
        XCTAssertTrue(any(app, "status-capsule").exists, "no status capsule")
        shot(app, "05-quotas-empty")

        // 路由组: the list comes from GET /v1/magpie/admin/routing-groups.
        // Every row: name, the 选用方式 chip, the model chain.
        openTab(app, "路由组")
        let row = app.buttons["group-\(config.group)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Coder missing")
        XCTAssertTrue(row.label.contains("Coder，按顺序，m-alpha，m-beta，m-gamma"), row.label)
        let pinnedRow = app.buttons["group-pinned"]
        XCTAssertTrue(pinnedRow.waitForExistence(timeout: 10), "Pinned missing")
        XCTAssertTrue(pinnedRow.label.contains("Pinned，手动，m-alpha，另有 1 个"), pinnedRow.label)
        shot(app, "06-routes")
        row.tap()

        // Coder, 按顺序: 设为首选 m-gamma just reorders, no alert.
        waitForGroup(app, "Coder")
        XCTAssertTrue(app.staticTexts["共 3 个模型"].exists, "no 共 3 个模型 under the title")
        XCTAssertTrue(app.staticTexts["组里的模型 · 从上往下用"].exists || any(app, "组里的模型 · 从上往下用").exists)
        let mode = app.buttons["routing-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        XCTAssertTrue(mode.label.contains("按顺序"), mode.label)
        XCTAssertTrue(any(app, "routing-mode-footer").label.contains("先用首选，用不了会自动往下用。"))
        XCTAssertTrue(any(app, "member-alpha/m-alpha").label.contains("首选"))
        let gamma = any(app, "member-gamma/m-gamma")
        XCTAssertTrue(gamma.waitForExistence(timeout: 10))
        XCTAssertFalse(gamma.label.contains("首选"), gamma.label)
        XCTAssertFalse(app.buttons["make-primary-alpha/m-alpha"].exists, "设为首选 on the 首选 row")
        shot(app, "07-group")

        // 在电脑上用这个组: group/coder, 拷贝 → 已拷贝.
        app.swipeUp()
        let agentModel = any(app, "agent-model")
        XCTAssertTrue(agentModel.waitForExistence(timeout: 5))
        XCTAssertTrue(agentModel.label.contains("group/\(config.group)") && !agentModel.label.contains("magpie/group/"), agentModel.label)
        app.buttons["copy-agent-model"].tap()
        expectToast(app, "已拷贝", "07b-copied")
        app.swipeDown()

        makePrimary(app, "gamma/m-gamma")
        // The toast only stays 2.5 s: look for it first, then make sure no alert came.
        expectToast(app, "已把 m-gamma 设为首选", "08-primary-in-order")
        XCTAssertFalse(app.alerts.firstMatch.exists, "按顺序 asked before 设为首选")
        XCTAssertTrue(any(app, "member-gamma/m-gamma").label.contains("首选"))

        // 选用方式 → 智能: no 首选 at all, the footer is 智能's line.
        chooseMode(app, raw: "smart", label: "智能", shotName: "09-routing-mode")
        expectToast(app, "已改成「智能」", "10-mode-saved")
        XCTAssertTrue(app.buttons["routing-mode"].label.contains("智能"), app.buttons["routing-mode"].label)
        XCTAssertTrue(any(app, "routing-mode-footer").label.contains("额度最先续上的先用；快用完的往后排。"))
        for id in ["alpha/m-alpha", "beta/m-beta", "gamma/m-gamma"] {
            XCTAssertFalse(any(app, "member-\(id)").label.contains("首选"), "首选 shown under 智能 on \(id)")
        }
        XCTAssertTrue(app.buttons["make-primary-alpha/m-alpha"].exists, "智能 has no 首选, so every row offers 设为首选")
        shot(app, "11-smart-no-primary")

        // 设为首选 m-beta under 智能: confirm 改成按顺序 first.
        makePrimary(app, config.member)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertEqual(alert.label, "改成按顺序？")
        let body = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '这个组现在是「智能」'")).firstMatch
        XCTAssertTrue(body.exists, "alert body does not name 智能")
        XCTAssertTrue(body.label.contains("以后一直先用 \(config.memberTitle)"), body.label)
        shot(app, "12-confirm-order")
        alert.buttons["改成按顺序"].tap()
        expectToast(app, "已改成按顺序，\(config.memberTitle) 是首选", "13-primary-saved")
        XCTAssertTrue(any(app, "member-\(config.member)").label.contains("首选"))
        XCTAssertTrue(app.buttons["routing-mode"].label.contains("按顺序"), app.buttons["routing-mode"].label)

        // 调整顺序 shows drag handles; 完成 with no move saves nothing.
        app.buttons["reorder-button"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["make-primary-gamma/m-gamma"].exists, "设为首选 shown while reordering")
        shot(app, "14-reorder")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["调整顺序"].waitForExistence(timeout: 10))

        // Pinned, 手动: 设为首选 picks at once and stays 手动.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(pinnedRow.waitForExistence(timeout: 10))
        pinnedRow.tap()
        waitForGroup(app, "Pinned")
        XCTAssertTrue(app.buttons["routing-mode"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["routing-mode"].label.contains("手动"), app.buttons["routing-mode"].label)
        XCTAssertTrue(any(app, "routing-mode-footer").label.contains("只用选定的这一个。"))
        XCTAssertTrue(any(app, "member-alpha/m-alpha").label.contains("首选"))
        let pinBeta = any(app, "member-beta/m-beta")
        XCTAssertFalse(pinBeta.label.contains("首选"), pinBeta.label)
        shot(app, "15-manual")
        makePrimary(app, "beta/m-beta")
        // The toast only stays 2.5 s: look for it first, then make sure no alert came.
        expectToast(app, "现在只用 m-beta", "16-manual-picked")
        XCTAssertFalse(app.alerts.firstMatch.exists, "手动 asked before 设为首选")
        XCTAssertTrue(any(app, "member-beta/m-beta").label.contains("首选"))
        XCTAssertFalse(any(app, "member-alpha/m-alpha").label.contains("首选"))
        XCTAssertTrue(app.buttons["routing-mode"].label.contains("手动"), app.buttons["routing-mode"].label)

        // Back on the list, pull to refresh re-reads magpie.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.swipeDown()
        let refreshed = app.buttons["group-\(config.group)"]
        XCTAssertTrue(refreshed.waitForExistence(timeout: 10))
        XCTAssertTrue(refreshed.label.contains("按顺序，m-beta，"), refreshed.label)
        XCTAssertTrue(app.buttons["group-pinned"].label.contains("手动，m-beta，另有 1 个"), app.buttons["group-pinned"].label)
        shot(app, "17-routes-after")

        // Stopped and deleted groups on the real magpie: the stopped one is
        // last, under 「已停用」, read-only; the deleted ones never show.
        if let stopped = config.disabledGroup {
            for id in config.deletedGroups ?? [] {
                XCTAssertFalse(app.buttons["group-\(id)"].exists, "deleted group \(id) shown")
            }
            let stoppedRow = app.buttons["group-\(stopped)"]
            for _ in 0..<6 where !(stoppedRow.exists && stoppedRow.isHittable) { app.swipeUp() }
            XCTAssertTrue(stoppedRow.waitForExistence(timeout: 10), "stopped group missing")
            XCTAssertTrue(stoppedRow.label.contains("已停用"), stoppedRow.label)
            XCTAssertTrue(any(app, "routing-disabled-header").exists, "no 已停用 header")
            let pinned = app.buttons["group-pinned"]
            if pinned.exists {
                XCTAssertGreaterThan(stoppedRow.frame.minY, pinned.frame.minY, "stopped group not last")
            }
            for id in config.deletedGroups ?? [] {
                XCTAssertFalse(app.buttons["group-\(id)"].exists, "deleted group \(id) shown")
            }
            shot(app, "17b-routes-stopped")
            stoppedRow.tap()
            XCTAssertTrue(any(app, "group-disabled-note").waitForExistence(timeout: 10), "no 已停用 note")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'make-primary-'")).firstMatch.exists,
                           "设为首选 on a stopped group")
            XCTAssertFalse(app.buttons["routing-mode"].exists, "选用方式 is a menu on a stopped group")
            XCTAssertFalse(app.staticTexts["改完马上生效。正在跑的会话做完手上这一步就会跟上。"].exists, "改完马上生效 on a stopped group")
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'member-' AND label CONTAINS '首选'")).firstMatch.exists, "首选 on a stopped group")
            shot(app, "17c-group-stopped")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        openTab(app, "设置")
        let key = app.staticTexts["settings-key"].firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertFalse(key.label.contains(String(config.key.dropFirst(10).prefix(12))), "key shown in full")
        XCTAssertFalse(app.staticTexts["网页版链接"].exists)
        XCTAssertTrue(any(app, "settings-status").label.contains("已连接"), any(app, "settings-status").label)
        XCTAssertTrue(any(app, "permission-quotas").label.contains("✓ 看额度"), any(app, "permission-quotas").label)
        XCTAssertTrue(any(app, "permission-routing").label.contains("✓ 改路由组"), any(app, "permission-routing").label)
        shot(app, "18-settings")
    }

    /// 1.4 on the real magpie: the Agent summary, 正在进行 from
    /// route-events, failures in words, 换到了, 「magpie 版本」 from /me,
    /// and 添加电脑 (the same magpie under a second address).
    func test4_agentFailuresLiveVersionAndSecondComputer() throws {
        let app = launchFresh()
        connect(app, key: config.key)
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20), "did not reach the tabs")

        if config.agentCalls == true {
            openTab(app, "Agent", ready: any(app, "agent-title-menu"))
            let summary = any(app, "agent-summary")
            XCTAssertTrue(summary.waitForExistence(timeout: 20), "no summary")
            XCTAssertTrue(summary.label.contains("Claude Code 调用"), summary.label)
            let live = any(app, "agent-live")
            XCTAssertTrue(live.waitForExistence(timeout: 30), "no 正在进行 card while a call runs")
            XCTAssertTrue(live.label.contains("正在进行") || live.label.contains("刚刚结束"), live.label)
            shot(app, "42-agent-real")

            let failures = any(app, "agent-summary-failures")
            XCTAssertTrue(failures.waitForExistence(timeout: 10), "no 失败 N 次 in the summary")
            failures.tap()
            let human = any(app, "call-human-line")
            XCTAssertTrue(human.waitForExistence(timeout: 15), "no failed rows in words")
            print("failure line: \(human.label)")
            XCTAssertFalse(human.label.isEmpty)
            shot(app, "43-calls-failed-real")
            // Not a handed-on call: those are not failures.
            XCTAssertFalse(any(app, "call-switched").exists, "a 换到了 row under 只看失败")
            app.descendants(matching: .any).matching(identifier: "all-call-row").firstMatch.tap()
            let original = any(app, "call-original")
            XCTAssertTrue(original.waitForExistence(timeout: 10), "no magpie 原话")
            print("original: \(original.label)")
            shot(app, "44-call-detail-real")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            any(app, "chip-switched").tap()
            let switched = any(app, "call-switched")
            if switched.waitForExistence(timeout: 10) {
                print("switched: \(switched.label)")
            } else {
                print("no 换到了 row: magpie did not record the handed-on call as retried")
            }
            shot(app, "45-calls-switched-real")
        }

        // 设置: 「magpie 版本」 from /me.
        openTab(app, "设置")
        let version = any(app, "settings-magpie-version")
        if !version.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(version.waitForExistence(timeout: 5), "no magpie 版本 row")
        XCTAssertTrue(version.label.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil, version.label)
        print("magpie 版本 row: \(version.label)")
        app.swipeDown()

        // 添加电脑: the same magpie under another address, named 第二台.
        let first = any(app, "settings-current-header").label
        any(app, "settings-add-computer").tap()
        XCTAssertTrue(app.navigationBars["添加电脑"].waitForExistence(timeout: 10), "no 添加电脑 screen")
        type("第二台", into: app.textFields["name-field"])
        let other = config.lan == true ? "http://127.0.0.1:3430" : "http://localhost:3430"
        type(other, into: app.textFields["address-field"])
        type(config.key, into: app.secureTextFields["key-field"])
        shot(app, "46-add-computer")
        app.buttons["connect-button"].tap()
        XCTAssertTrue(app.navigationBars["添加电脑"].waitForNonExistence(timeout: 20), "add did not finish")
        dismissSystemPrompts(app)
        XCTAssertTrue(any(app, "settings-current-header").waitForExistence(timeout: 10))
        XCTAssertEqual(any(app, "settings-current-header").label, "第二台")
        XCTAssertTrue(any(app, "computer-row-\(first)").exists, "the first computer is gone")
        shot(app, "47-settings-two-computers")

        // Back to the first one from the capsule menu.
        openTab(app, "额度")
        any(app, "status-capsule").tap()
        let back = menuItem(app, first)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no \(first) in the menu")
        back.tap()
        expectToast(app, "已换到 \(first)", "48-switched-back")
        XCTAssertTrue(any(app, "status-capsule").label.contains(first) || "\(any(app, "status-capsule").value ?? "")".contains(first))
    }

    // MARK: 1.5 slow network

    /// Relaunch on the saved computer (no reset), with the Debug network hook.
    private func relaunch(_ app: XCUIApplication, _ environment: [String: String]) -> XCUIApplication {
        app.terminate()
        let next = XCUIApplication()
        next.launchArguments += ["-perch-long-toasts", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        next.launchEnvironment = environment
        next.launch()
        return next
    }

    private func waitLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(for: [expectation(for: p, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// Cache first, then each refresh outcome against the real magpie:
    /// slow (正在刷新 → 还在刷新 → 刚刚更新, saved data shown throughout),
    /// one block failing (card footer), the page failing while magpie
    /// answers (banner + 重试) and magpie unreachable (offline card).
    func test5_slowNetworkCacheFirstAndFailures() throws {
        var app = launchFresh()
        connect(app, key: config.key)
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20), "did not reach the tabs")
        dismissSystemPrompts(app)
        // Fill the cache: Agent's page and 路由组 (with the agent's newest call).
        openTab(app, "Agent", ready: any(app, "agent-title-menu"))
        XCTAssertTrue(any(app, "agent-tile-calls").waitForExistence(timeout: 20) || any(app, "agent-empty").exists, "Agent did not load")
        let agentHasCalls = any(app, "agent-tile-calls").exists
        openTab(app, "路由组")
        XCTAssertTrue(app.buttons["group-\(config.group)"].waitForExistence(timeout: 20), "no groups")
        let target = any(app, "agent-target-header")
        let hasTarget = target.waitForExistence(timeout: 10)
        let capsule = any(app, "status-capsule")
        XCTAssertTrue(waitLabel(capsule, contains: "刚刚更新", timeout: 15), "capsule: \(capsule.label)")
        XCTAssertFalse(any(app, "quotas-read-time").exists, "the old 「读取」 footer is back")
        shot(app, "60-slownet-fresh")

        // 1. Slow (7 s a request, under the 8 s groups timeout): the saved groups show at once, read-only
        //    nothing blank; 正在刷新, 还在刷新 after 4 s, then 刚刚更新.
        app = relaunch(app, ["PERCH_NET_DELAY_MS": "7000"])
        openTab(app, "路由组")
        XCTAssertTrue(app.buttons["group-\(config.group)"].waitForExistence(timeout: 3), "the saved groups did not show at once")
        XCTAssertFalse(any(app, "loading").exists, "a skeleton over saved data")
        let slowCapsule = any(app, "status-capsule")
        XCTAssertTrue(slowCapsule.label.contains("正在刷新") || slowCapsule.label.contains("还在刷新") || waitLabel(slowCapsule, contains: "刷新", timeout: 3),
                      "no 正在刷新: \(slowCapsule.label)")
        shot(app, "61-slownet-refreshing")
        XCTAssertTrue(waitLabel(slowCapsule, contains: "还在刷新", timeout: 8), "no 还在刷新: \(slowCapsule.label)")
        XCTAssertTrue(app.buttons["group-\(config.group)"].exists, "the saved groups went away while slow")
        shot(app, "62-slownet-still")
        XCTAssertTrue(waitLabel(slowCapsule, contains: "刚刚更新", timeout: 20), "never 刚刚更新: \(slowCapsule.label)")
        XCTAssertFalse(any(app, "stale-banner").exists, "a banner after a slow but good refresh")
        if agentHasCalls {
            openTab(app, "Agent", ready: any(app, "agent-title-menu"))
            XCTAssertTrue(any(app, "agent-tile-calls").waitForExistence(timeout: 3), "Agent's saved page did not show at once")
            // The saved sentence doesn't count up from 0; it says the
            // 调用 tile's number from the first frame.
            let sentence = any(app, "agent-summary")
            if sentence.exists {
                let first = { (s: String) in s.range(of: #"[0-9][0-9,]*"#, options: .regularExpression).map { String(s[$0]) } }
                let tile = any(app, "agent-tile-calls").value as? String ?? ""
                XCTAssertEqual(first(sentence.label), first(tile), "summary \(sentence.label) vs tile \(tile)")
            }
        }

        // 2. One block fails (the agent's calls): 路由组's 「刚刚在用」 card
        //    keeps its call with a footer; Agent's page says it didn't read.
        app = relaunch(app, ["PERCH_NET_FAIL_PATHS": "/v1/magpie/usage/requests"])
        openTab(app, "路由组")
        XCTAssertTrue(app.buttons["group-\(config.group)"].waitForExistence(timeout: 5))
        if hasTarget {
            let footer = any(app, "card-stale-footer")
            XCTAssertTrue(footer.waitForExistence(timeout: 25), "no 这张没读到最新的 footer")
            XCTAssertTrue(footer.label.contains("这张没读到最新的，还是"), footer.label)
            XCTAssertTrue(any(app, "agent-target-header").exists, "the saved 刚刚在用 card went away")
            XCTAssertFalse(any(app, "stale-banner").exists, "a whole-page banner for one block")
            shot(app, "63-slownet-block-failed")
        } else {
            print("no 刚刚在用 card on this magpie: the block-footer check skips")
        }
        if agentHasCalls {
            openTab(app, "Agent", ready: any(app, "agent-title-menu"))
            XCTAssertTrue(any(app, "agent-tile-calls").exists, "Agent's saved page went away")
            let banner = any(app, "stale-banner")
            XCTAssertTrue(banner.waitForExistence(timeout: 25), "no banner when the calls didn't read")
            XCTAssertTrue(banner.label.contains("没读到最新的，下面是") || any(app, "stale-retry").exists, banner.label)
            shot(app, "64-slownet-agent-banner")
        }

        // 3. magpie answers /me but no data (timeout): banner + 重试, the
        //    capsule keeps the last time and stops spinning after 12 s.
        app = relaunch(app, ["PERCH_NET_FAIL": "timeout"])
        openTab(app, "路由组")
        XCTAssertTrue(app.buttons["group-\(config.group)"].waitForExistence(timeout: 5))
        let banner = any(app, "stale-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 25), "no 没读到最新的 banner")
        let failedCapsule = any(app, "status-capsule")
        XCTAssertTrue(failedCapsule.label.contains("更新") && !failedCapsule.label.contains("刷新") && !failedCapsule.label.contains("连不上"),
                      "capsule after a failed refresh: \(failedCapsule.label)")
        // The banner's clock time, never 刚刚 / x 分钟前 (the
        // cache was filled under a minute ago).
        XCTAssertFalse(failedCapsule.label.contains("刚刚") || failedCapsule.label.contains("分钟前"),
                       "capsule beside the banner says a relative time: \(failedCapsule.label)")
        if let clock = failedCapsule.label.range(of: #"\d{2}:\d{2}"#, options: .regularExpression) {
            XCTAssertTrue(banner.label.contains(String(failedCapsule.label[clock])) || !banner.label.contains("下面是"),
                          "capsule \(failedCapsule.label) and banner \(banner.label) give different times")
        } else {
            XCTFail("no clock time in the capsule: \(failedCapsule.label)")
        }
        shot(app, "65-slownet-failed-banner")
        let retry = any(app, "stale-retry")
        XCTAssertTrue(retry.exists, "no 重试")
        retry.tap()
        XCTAssertTrue(waitLabel(failedCapsule, contains: "刷新", timeout: 3), "重试 didn't start a refresh: \(failedCapsule.label)")
        XCTAssertTrue(banner.exists, "the banner left while retrying")
        XCTAssertTrue(waitLabel(failedCapsule, contains: "更新", timeout: 20), "retry never ended: \(failedCapsule.label)")
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "no banner after the retry failed too")

        // 4. Unreachable: offline card, the saved groups dimmed, 连不上.
        app = relaunch(app, ["PERCH_NET_FAIL": "offline"])
        openTab(app, "路由组")
        XCTAssertTrue(app.buttons["group-\(config.group)"].waitForExistence(timeout: 5), "the saved groups did not show")
        let offline = any(app, "offline-card")
        XCTAssertTrue(offline.waitForExistence(timeout: 20), "no offline card")
        let offCapsule = any(app, "status-capsule")
        XCTAssertTrue(waitLabel(offCapsule, contains: "连不上", timeout: 5), "capsule: \(offCapsule.label)")
        XCTAssertFalse(any(app, "stale-banner").exists, "a banner as well as the offline card")
        XCTAssertFalse(any(app, "card-stale-footer").exists, "a card footer as well as the offline card")
        shot(app, "66-slownet-offline")
        openTab(app, "额度")
        XCTAssertTrue(any(app, "offline-card").waitForExistence(timeout: 20), "no offline card on 额度")
        XCTAssertFalse(any(app, "card-stale-footer").exists, "a card footer on 额度 while 连不上")
        XCTAssertFalse(any(app, "stale-banner").exists, "a banner on 额度 while 连不上")
        if agentHasCalls {
            openTab(app, "Agent", ready: any(app, "agent-title-menu"))
            XCTAssertTrue(any(app, "offline-card").waitForExistence(timeout: 20), "no offline card on Agent")
            XCTAssertFalse(any(app, "card-stale-footer").exists, "a block footer on Agent while 连不上")
            XCTAssertFalse(any(app, "stale-banner").exists, "a banner on Agent while 连不上")
        }

        // Back on a good network: the card goes, 刚刚更新.
        app = relaunch(app, [:])
        openTab(app, "路由组")
        XCTAssertTrue(waitLabel(any(app, "status-capsule"), contains: "刚刚更新", timeout: 20))
        XCTAssertFalse(any(app, "offline-card").exists)
        XCTAssertFalse(any(app, "stale-banner").exists)
    }

    // MARK: Upgrade from an older build (scripts/upgrade.sh)

    /// scripts/upgrade.sh installs an older build ($OLD_REV, Release) and runs
    /// step `old`, then installs this build (Release) over it and runs `new`:
    /// a user's update path. Unset: not an upgrade run.
    private var upgradeStep: String? { ProcessInfo.processInfo.environment["PERCH_UPGRADE_STEP"] }

    private func visitEveryTab(_ app: XCUIApplication) {
        openTab(app, "Agent", ready: any(app, "agent-title-menu"))
        sleep(3)
        openTab(app, "路由组")
        sleep(3)
        openTab(app, "设置")
        sleep(1)
        openTab(app, "额度")
        sleep(3)
    }

    /// The old build: connect, use every tab, so it saves what it saves.
    func test8a_upgradeOldBuildSavesState() throws {
        guard upgradeStep == "old" else { throw XCTSkip("upgrade runs only in scripts/upgrade.sh") }
        let app = launchFresh()
        connect(app, key: config.key)
        for i in 0..<15 where !app.navigationBars["额度"].exists {
            dismissSystemPrompts(app)
            let button = app.buttons["connect-button"]
            if i % 4 == 3, button.exists, button.isHittable { button.tap() }
            sleep(2)
        }
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 10), "the old build did not reach the tabs")
        dismissSystemPrompts(app)
        visitEveryTab(app)
        shot(app, "80-upgrade-old")
        app.terminate()
    }

    /// This build over the old one, launched the way the Home Screen does
    /// (no arguments): it must come up and stay up, twice (the second
    /// launch reads what this build saved itself).
    func test8b_upgradeNewBuildLaunches() throws {
        guard upgradeStep == "new" else { throw XCTSkip("upgrade runs only in scripts/upgrade.sh") }
        for round in 1...2 {
            let app = XCUIApplication()
            app.launch()
            sleep(6)
            XCTAssertEqual(app.state, .runningForeground, "launch \(round) after the upgrade: the app is not running (crashed?)")
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "launch \(round): no tabs (the saved computer was lost?)")
            visitEveryTab(app)
            XCTAssertEqual(app.state, .runningForeground, "launch \(round): the app died while using the tabs")
            shot(app, "8\(round)-upgrade-new")
            app.terminate()
        }
    }

    /// The same, with magpie gone (`dead`: connection refused) or hanging
    /// (`hang`: accepts, never answers), past the 12 s budget and the /me
    /// probe: the Release failure paths, without the Debug network hook.
    func test8c_upgradeNewBuildWithoutMagpie() throws {
        guard let step = upgradeStep, step == "dead" || step == "hang" else { throw XCTSkip("upgrade runs only in scripts/upgrade.sh") }
        let app = XCUIApplication()
        app.launch()
        for second in stride(from: 0, through: 30, by: 3) {
            sleep(3)
            XCTAssertEqual(app.state, .runningForeground, "\(step): the app died about \(second + 3) s after launch")
        }
        visitEveryTab(app)
        sleep(15)
        XCTAssertEqual(app.state, .runningForeground, "\(step): the app died while using the tabs")
        shot(app, "83-upgrade-\(step)")
        app.terminate()
    }

    // MARK: 1.5 slow-network recordings (scripts/e2e.sh's second pass)

    /// The host folder scripts/e2e.sh watches: `<name>.start` starts
    /// `simctl io recordVideo`, `<name>.stop` ends it. Unset: not a video run.
    private var videoDir: URL? {
        ProcessInfo.processInfo.environment["PERCH_VIDEO_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private func waitFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            usleep(100_000)
        }
        return false
    }

    /// Connect, fill the caches (Agent's page, 路由组 with its newest call),
    /// quit: each clip starts from saved data.
    private func videoSetup() throws -> URL {
        guard let dir = videoDir else { throw XCTSkip("recordings run only in scripts/e2e.sh's video pass") }
        let app = launchFresh()
        connect(app, key: config.key)
        // A fresh Simulator asks for 本地网络 on the first connect: allow,
        // connect again if that first try was refused.
        for i in 0..<15 where !app.navigationBars["额度"].exists {
            dismissSystemPrompts(app)
            let button = app.buttons["connect-button"]
            if i % 4 == 3, button.exists, button.isHittable { button.tap() }
            sleep(2)
        }
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 10), "did not reach the tabs")
        dismissSystemPrompts(app)
        openTab(app, "Agent", ready: any(app, "agent-title-menu"))
        XCTAssertTrue(any(app, "agent-tile-calls").waitForExistence(timeout: 20), "Agent did not load")
        openTab(app, "路由组")
        XCTAssertTrue(app.buttons["group-\(config.group)"].waitForExistence(timeout: 20), "no groups")
        _ = any(app, "agent-target-header").waitForExistence(timeout: 10)
        XCTAssertTrue(waitLabel(any(app, "status-capsule"), contains: "刚刚更新", timeout: 15))
        // Let a few more calls land (e2e.sh keeps making them) so the
        // refresh in the clip rolls numbers to new values.
        sleep(6)
        app.terminate()
        return dir
    }

    /// Records `body` as `<name>.mp4` (under 30 s).
    private func clip(_ name: String, in dir: URL, _ body: () -> Void) {
        let started = Date()
        FileManager.default.createFile(atPath: dir.appending(path: name + ".start").path, contents: nil)
        XCTAssertTrue(waitFile(dir.appending(path: name + ".recording"), timeout: 20), "the recording of \(name) did not start")
        usleep(500_000)
        body()
        sleep(2)
        FileManager.default.createFile(atPath: dir.appending(path: name + ".stop").path, contents: nil)
        XCTAssertTrue(waitFile(dir.appending(path: name + ".done"), timeout: 30), "the recording of \(name) did not end")
        print("SLOWNET-VIDEO \(name): \(Int(Date().timeIntervalSince(started))) s")
    }

    private func launchVideo(_ environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-perch-long-toasts", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment = environment
        app.launch()
        return app
    }

    /// Slow (7 s a request): saved numbers at once, 正在刷新 → 还在刷新 →
    /// 刚刚更新, the call count rolling to the new value.
    func test9a_videoSlow() throws {
        let dir = try videoSetup()
        clip("1-slow", in: dir) {
            let app = launchVideo(["PERCH_NET_DELAY_MS": "7000"])
            openTab(app, "Agent", ready: any(app, "agent-title-menu"))
            let capsule = any(app, "status-capsule")
            XCTAssertTrue(waitLabel(capsule, contains: "还在刷新", timeout: 10), "no 还在刷新: \(capsule.label)")
            XCTAssertTrue(waitLabel(capsule, contains: "刚刚更新", timeout: 15), "never 刚刚更新: \(capsule.label)")
            sleep(2)
        }
    }

    /// The agent's calls don't read: 路由组's 刚刚在用 card keeps its call
    /// with the footer; a tap on it (the failure over) reads it again.
    func test9b_videoBlockFailed() throws {
        let dir = try videoSetup()
        clip("2-block-failed", in: dir) {
            let app = launchVideo(["PERCH_NET_FAIL_PATHS": "/v1/magpie/usage/requests", "PERCH_NET_FAIL_FOR_S": "12"])
            openTab(app, "路由组")
            let footer = any(app, "card-stale-footer")
            XCTAssertTrue(footer.waitForExistence(timeout: 20), "no card footer")
            XCTAssertFalse(any(app, "stale-banner").exists)
            sleep(3)
            footer.tap()
            let gone = NSPredicate(format: "exists == false")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: footer)], timeout: 12), .completed, "the footer stayed after a good retry")
            sleep(1)
        }
    }

    /// Nothing reads while magpie answers /me: banner + 重试 at 12 s; 重试
    /// (the failure over) refreshes, the banner goes, numbers roll.
    func test9c_videoPageFailed() throws {
        let dir = try videoSetup()
        clip("3-page-failed", in: dir) {
            let app = launchVideo(["PERCH_NET_FAIL": "timeout", "PERCH_NET_FAIL_FOR_S": "13"])
            openTab(app, "Agent", ready: any(app, "agent-title-menu"))
            let banner = any(app, "stale-banner")
            XCTAssertTrue(banner.waitForExistence(timeout: 20), "no banner")
            let capsule = any(app, "status-capsule")
            XCTAssertFalse(capsule.label.contains("刚刚") || capsule.label.contains("分钟前"), "capsule beside the banner: \(capsule.label)")
            sleep(2)
            any(app, "stale-retry").tap()
            XCTAssertTrue(waitLabel(any(app, "status-capsule"), contains: "刚刚更新", timeout: 12), "retry did not refresh")
            let gone = NSPredicate(format: "exists == false")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: banner)], timeout: 5), .completed, "the banner stayed")
        }
    }

    /// Unreachable: the offline card, saved data dimmed, 连不上, no footers;
    /// then the computer is back: 重试 reconnects, numbers roll.
    func test9d_videoOffline() throws {
        let dir = try videoSetup()
        clip("4-offline", in: dir) {
            let app = launchVideo(["PERCH_NET_FAIL": "offline", "PERCH_NET_FAIL_FOR_S": "9"])
            openTab(app, "Agent", ready: any(app, "agent-title-menu"))
            let card = any(app, "offline-card")
            XCTAssertTrue(card.waitForExistence(timeout: 15), "no offline card")
            XCTAssertTrue(waitLabel(any(app, "status-capsule"), contains: "连不上", timeout: 5))
            XCTAssertFalse(any(app, "card-stale-footer").exists, "a footer while 连不上")
            XCTAssertFalse(any(app, "stale-banner").exists, "a banner while 连不上")
            sleep(6)
            any(app, "offline-retry").tap()
            XCTAssertTrue(waitLabel(any(app, "status-capsule"), contains: "刚刚更新", timeout: 12), "did not reconnect")
            XCTAssertFalse(card.exists, "the offline card stayed")
        }
    }

    /// The Agent summary shows its saved number at once,
    /// never counting up from 0, then rolls old → new on a refresh, the
    /// same number as the 调用 tile whenever they're read.
    func test9e_videoSummary() throws {
        let dir = try videoSetup()
        clip("5-summary", in: dir) {
            let app = launchVideo([:])
            openTab(app, "Agent", ready: any(app, "agent-title-menu"))
            let sentence = any(app, "agent-summary")
            let tile = any(app, "agent-tile-calls")
            XCTAssertTrue(sentence.waitForExistence(timeout: 5), "no summary")
            let number = { (s: String) in s.range(of: #"[0-9][0-9,]*"#, options: .regularExpression).map { String(s[$0]) } }
            var seen: [String] = []
            func check() -> String? {
                let said = number(sentence.label), shows = number("\(tile.value ?? "")")
                XCTAssertEqual(said, shows, "summary \(sentence.label) vs tile \(tile.value ?? "")")
                XCTAssertNotEqual(said, "0", "the summary says 0: \(sentence.label)")
                if let said, seen.last != said { seen.append(said) }
                return said
            }
            let first = check()
            for _ in 0..<6 { _ = check(); usleep(250_000) }
            // Pull to refresh until a newer count lands (e2e.sh keeps making calls).
            for _ in 0..<2 where check() == first {
                app.swipeDown()
                for _ in 0..<24 where check() == first { usleep(250_000) }
            }
            for _ in 0..<6 { _ = check(); usleep(250_000) }
            XCTAssertTrue(waitLabel(any(app, "status-capsule"), contains: "刚刚更新", timeout: 12))
            print("SUMMARY-NUMBERS \(seen.joined(separator: " "))")
        }
    }

    /// A computer in the capsule menu. iOS menu items with a subtitle do not
    /// always carry their identifier, so fall back to the item's label.
    private func menuItem(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let byID = any(app, "computer-menu-\(name)")
        if byID.waitForExistence(timeout: 2) { return byID }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }
}
