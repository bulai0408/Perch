import XCTest

/// Screenshots on demo data (`-perch-demo`, DEBUG only), no
/// magpie needed. scripts/shots.sh runs this class on iPhone 18 Pro in light
/// and dark and on an SE-size iPhone; `PERCH_SHOT_TAG` (light / dark / se)
/// prefixes each attachment. scripts/e2e.sh skips it.
final class PerchShotsTests: XCTestCase {
    private var tag: String { ProcessInfo.processInfo.environment["PERCH_SHOT_TAG"] ?? "shot" }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: helpers

    private func launchDemo(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-perch-reset", "-perch-demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        // Let springs and the sky settle first.
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(tag)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openTab(_ app: XCUIApplication, _ name: String, ready: XCUIElement) {
        let buttons = app.tabBars.buttons.matching(NSPredicate(format: "label == %@", name))
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 10), "no \(name) tab")
        for _ in 0..<3 {
            for i in 0..<max(buttons.count, 1) {
                let button = buttons.element(boundBy: i)
                guard button.exists, button.isHittable else { continue }
                button.tap()
                if ready.waitForExistence(timeout: 4) { return }
            }
            sleep(1)
        }
        XCTAssertTrue(ready.exists, "tab \(name) did not open")
    }

    /// Scrolls in small drags until `element` sits fully above the tab bar.
    private func bringOnScreen(_ app: XCUIApplication, _ element: XCUIElement) {
        let bottom = app.windows.firstMatch.frame.maxY - 100
        for _ in 0..<10 where !element.exists || element.frame.maxY > bottom {
            let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -220)))
        }
    }

    // MARK: shots

    /// Agent with data, 最近的调用, 路由组, 组详情, 设置 top and 关于.
    func testA_stage2Screens() throws {
        let app = launchDemo()
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20))
        XCTAssertTrue(any(app, "quota-hero").waitForExistence(timeout: 10))
        shot(app, "00-quotas")

        openTab(app, "Agent", ready: any(app, "agent-title-menu"))
        XCTAssertTrue(any(app, "agent-tile-calls").waitForExistence(timeout: 10))
        shot(app, "01-agent")

        let allCalls = any(app, "agent-all-calls")
        bringOnScreen(app, allCalls)
        XCTAssertTrue(allCalls.waitForExistence(timeout: 5))
        allCalls.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "all-call-row").firstMatch.waitForExistence(timeout: 10))
        shot(app, "03-recent-calls")

        openTab(app, "路由组", ready: app.navigationBars["路由组"])
        XCTAssertTrue(app.buttons["group-coder"].waitForExistence(timeout: 10))
        shot(app, "04-routes")
        app.buttons["group-coder"].tap()
        XCTAssertTrue(any(app, "group-detail").waitForExistence(timeout: 10))
        shot(app, "05-group")

        // A group stopped on the computer: last, under 「已停用」, dimmed;
        // its detail is read-only. The deleted found group never shows.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["group-coder"].waitForExistence(timeout: 10))
        let night = app.buttons["group-night"]
        // On an SE the row is below the fold, and List makes no off-screen rows.
        for _ in 0..<8 where !(night.exists && night.isHittable && night.frame.maxY < app.windows.firstMatch.frame.maxY - 100) {
            app.swipeUp()
        }
        XCTAssertTrue(night.waitForExistence(timeout: 5), "no stopped group")
        XCTAssertFalse(app.buttons["group-auto-m-alpha"].exists, "deleted group shown")
        XCTAssertTrue(night.label.contains("已停用"), night.label)
        XCTAssertTrue(any(app, "routing-disabled-header").exists, "no 已停用 header")
        shot(app, "04b-routes-disabled")
        night.tap()
        XCTAssertTrue(any(app, "group-disabled-note").waitForExistence(timeout: 10), "no 已停用 note")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'make-primary-'")).firstMatch.exists, "设为首选 on a stopped group")
        XCTAssertFalse(app.buttons["routing-mode"].exists, "选用方式 is a menu on a stopped group")
        XCTAssertFalse(app.staticTexts["改完马上生效。正在跑的会话做完手上这一步就会跟上。"].exists, "改完马上生效 on a stopped group")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'member-' AND label CONTAINS '首选'")).firstMatch.exists, "首选 on a stopped group")
        shot(app, "05b-group-disabled")

        openTab(app, "设置", ready: app.navigationBars["设置"])
        XCTAssertTrue(any(app, "settings-status").waitForExistence(timeout: 10))
        shot(app, "06-settings-top")
        let about = any(app, "about-header")
        bringOnScreen(app, about)
        XCTAssertTrue(about.exists, "no 关于 header")
        app.swipeUp()
        shot(app, "07-settings-about")
    }

    /// Agent with no calls: 「还没有 Agent 来过」.
    func testB_agentEmpty() throws {
        let app = launchDemo(["PERCH_DEMO_STATE": "empty"])
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 20))
        openTab(app, "Agent", ready: any(app, "agent-period"))
        XCTAssertTrue(any(app, "agent-empty").waitForExistence(timeout: 10))
        shot(app, "02-agent-empty")
    }

    // MARK: 1.5 slow network

    private func capsule(_ app: XCUIApplication, contains text: String) {
        let capsule = any(app, "status-capsule")
        XCTAssertTrue(capsule.waitForExistence(timeout: 10), "no capsule")
        let shown = NSPredicate(format: "label CONTAINS %@", text)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: shown, evaluatedWith: capsule)], timeout: 10), .completed,
                       "capsule says \(capsule.label), not \(text)")
        XCTAssertTrue(capsule.label.contains("office-mac"), capsule.label)
    }

    /// 额度 while refreshing (正在刷新) and slow (还在刷新): saved data at 100 %.
    func testC_slowNetRefreshing() throws {
        for (state, word, name) in [("refreshing", "正在刷新", "10-quotas-refreshing"), ("slow", "还在刷新", "11-quotas-slow")] {
            let app = launchDemo(["PERCH_DEMO_STATE": state])
            XCTAssertTrue(any(app, "quota-hero").waitForExistence(timeout: 20))
            capsule(app, contains: word)
            XCTAssertFalse(any(app, "stale-banner").exists)
            shot(app, name)
            if state == "refreshing" {
                openTab(app, "Agent", ready: any(app, "agent-tile-calls"))
                capsule(app, contains: word)
                shot(app, "15-agent-refreshing")
            }
            app.terminate()
        }
    }

    /// Whole page failed: banner with 重试; one card failed: its footer.
    func testD_slowNetFailed() throws {
        var app = launchDemo(["PERCH_DEMO_STATE": "stale"])
        XCTAssertTrue(any(app, "quota-hero").waitForExistence(timeout: 20))
        let banner = any(app, "stale-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no banner")
        XCTAssertTrue(any(app, "stale-retry").exists, "no 重试")
        capsule(app, contains: "更新")
        shot(app, "12-quotas-failed")
        app.terminate()

        app = launchDemo(["PERCH_DEMO_STATE": "partial"])
        XCTAssertTrue(any(app, "quota-hero").waitForExistence(timeout: 20))
        let footer = any(app, "card-stale-footer")
        bringOnScreen(app, footer)
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "no card footer")
        XCTAssertFalse(any(app, "stale-banner").exists)
        shot(app, "13-quotas-partial")
        app.terminate()
    }

    /// Unreachable: the offline card, data dimmed, capsule 连不上.
    func testE_slowNetOffline() throws {
        let app = launchDemo(["PERCH_DEMO_STATE": "offline"])
        XCTAssertTrue(any(app, "offline-card").waitForExistence(timeout: 20), "no offline card")
        capsule(app, contains: "连不上")
        shot(app, "14-quotas-offline")
    }
}
