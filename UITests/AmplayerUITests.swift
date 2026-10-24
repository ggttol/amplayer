import XCTest

/// 驱动真实界面的端到端测试。依赖：模拟器 Documents 里有测试音频；
/// Mac 上的 rclone WebDAV 容器在 127.0.0.1:18080（见 Tools/test-servers.sh）。
@MainActor
final class AmplayerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private var time: XCUIElement { app.otherElements["time"].firstMatch }

    /// 等元素出现且可点（导航动画结束）后再点
    private func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(element, timeout: timeout, file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        Thread.sleep(forTimeInterval: 0.6)
        element.tap()
    }

    /// 等待元素出现；超时时打印界面层级方便排查
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if !element.waitForExistence(timeout: timeout) {
            print("UIDUMP-BEGIN\n\(app.debugDescription)\nUIDUMP-END")
            XCTFail("等待超时：\(element)", file: file, line: line)
        }
    }

    private func waitForState(_ text: String, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let exp = expectation(for: predicate, evaluatedWith: time)
        wait(for: [exp], timeout: timeout)
    }

    /// 本机文件：播放、暂停、继续、下一首、停止
    func testTransportControls() {
        app.launchArguments = ["-AmplayerReset", "YES", "-AmplayerDemoPlay", "YES"]
        app.launch()
        waitForState("播放中")
        app.buttons["暂停"].tap()
        waitForState("已暂停")
        app.buttons["暂停"].tap()
        waitForState("播放中")
        let before = time.value as? String ?? ""
        app.buttons["下一首"].tap()
        waitForState("播放中")
        XCTAssertNotEqual(time.value as? String, before)
        app.buttons["停止"].tap()
        waitForState("已停止")
    }

    /// 均衡器预设与开关
    func testEqualizerPreset() {
        app.launchArguments = ["-AmplayerReset", "YES"]
        app.launch()
        app.buttons["预设"].tap()
        app.buttons["Rock"].tap()
        let band = app.otherElements["60 赫兹"].firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 5))
        XCTAssertEqual(band.value as? String, "+5.0 dB")
        app.buttons["预设"].tap()
        app.buttons["Flat"].tap()
        XCTAssertEqual(band.value as? String, "+0.0 dB")
    }

    /// 通过表单添加 WebDAV 来源 → 测试连接 → 保存 → 浏览 → 点歌播放
    func testAddWebDAVSourceAndPlay() {
        app.launchArguments = ["-AmplayerReset", "YES"]
        app.launch()
        app.buttons["来源"].firstMatch.tap()
        app.buttons["添加"].tap()
        app.buttons["WebDAV / Alist / OpenList"].tap()

        let name = app.textFields["名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.press(forDuration: 1.2)
        if app.menuItems["全选"].waitForExistence(timeout: 2) { app.menuItems["全选"].tap() }
        name.typeText("Test DAV")
        let url = app.textFields.element(boundBy: 1)
        url.tap()
        url.typeText("http://127.0.0.1:18080/")
        let user = app.textFields["用户名"]
        user.tap()
        user.typeText("amplayer")
        let password = app.secureTextFields["密码"]
        password.tap()
        password.typeText("amplayerpass")

        app.buttons["测试连接"].tap()
        let ok = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "连接成功")).firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 15), "WebDAV 测试连接失败")
        app.buttons["保存"].tap()
        // 等编辑表单完全收起，否则点到的是被遮住的行
        let editorGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["测试连接"])
        wait(for: [editorGone], timeout: 5)
        // 系统“保存密码？”提示（密码 App）出现时间不固定：轮询，看到就点“以后”，直到来源行可点
        let cell = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Test DAV")).firstMatch
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && !(cell.exists && cell.isHittable) {
            for owner in [app!, springboard] where owner.buttons["以后"].exists {
                owner.buttons["以后"].tap()
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        if !cell.isHittable {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(cell.isHittable)
        cell.tap()
        let folder = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Album One")).firstMatch
        tapWhenReady(folder)
        let song = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Wave Check")).firstMatch
        tapWhenReady(song)
        waitForState("播放中", timeout: 20)
        XCTAssertTrue((time.value as? String ?? "").contains("Wave Check"))
    }

    /// 皮肤列表可打开并切换回内置皮肤
    func testSkinsSheet() {
        app.launchArguments = ["-AmplayerReset", "YES"]
        app.launch()
        app.buttons["皮肤"].firstMatch.tap()
        let builtIn = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Amplayer Graphite")).firstMatch
        XCTAssertTrue(builtIn.waitForExistence(timeout: 5))
        builtIn.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 5))
    }
}
