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
        app.buttons["菜单"].tap()
        tapWhenReady(app.buttons["menu.音乐来源"])
        tapWhenReady(app.buttons["添加"])
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
        app.buttons["菜单"].tap()
        // 侧边菜单较长，“皮肤”可能在第一屏以外
        let skinsItem = app.buttons["menu.皮肤"]
        for _ in 0..<4 where !skinsItem.waitForExistence(timeout: 1) { app.swipeUp() }
        tapWhenReady(skinsItem)
        let builtIn = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Amplayer Graphite")).firstMatch
        XCTAssertTrue(builtIn.waitForExistence(timeout: 5))
        builtIn.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 5))
    }

    /// 点歌名直接播放；长按进入多选后点歌名是勾选
    func testPlaylistTapPlaysAndMultiSelect() {
        app.launchArguments = ["-AmplayerReset", "YES", "-AmplayerDemoPlay", "YES", "-amplayer.showPL", "YES", "-amplayer.showLyrics", "NO"]
        app.launch()
        waitForState("播放中")
        let row3 = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "3. ")).firstMatch
        tapWhenReady(row3)
        let playing3 = expectation(for: NSPredicate(format: "value CONTAINS %@", "Wave Check"), evaluatedWith: time)
        wait(for: [playing3], timeout: 15)

        let row1 = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "1. ")).firstMatch
        row1.press(forDuration: 1.0)
        tapWhenReady(app.buttons["多选"])
        let bar = app.staticTexts["已选 1 首"]
        waitFor(bar)
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "2. ")).firstMatch.tap()
        waitFor(app.staticTexts["已选 2 首"])
        // 多选时点行不切歌
        XCTAssertTrue((time.value as? String ?? "").contains("Wave Check"))
        app.buttons["完成"].tap()
        XCTAssertFalse(app.staticTexts["已选 2 首"].waitForExistence(timeout: 1))
    }

    private func row(_ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// 长按菜单“移动 › 移到最前”；清空列表后歌词面板不再显示旧歌词
    func testPlaylistMoveAndClear() {
        app.launchArguments = ["-AmplayerReset", "YES", "-AmplayerDemoPlay", "YES", "-amplayer.showPL", "YES", "-amplayer.showLyrics", "NO"]
        app.launch()
        waitForState("播放中")
        let third = row("3. ")
        waitFor(third)
        let title = (third.label.components(separatedBy: ", ").first ?? third.label).replacingOccurrences(of: "3. ", with: "")
        third.press(forDuration: 1.0)
        tapWhenReady(app.buttons["移动"])
        tapWhenReady(app.buttons["移到最前"])
        let firstNow = row("1. " + title)
        XCTAssertTrue(firstNow.waitForExistence(timeout: 5), "移到最前后第一行应是 \(title)")

        // 切到歌词（第 1 首示例曲旁边有 .lrc 的那首正在播放时才有歌词；这里只验证清空后的状态）
        app.buttons["切换到歌词"].tap()
        tapWhenReady(app.buttons["删除曲目"])
        tapWhenReady(app.buttons["清空列表"])
        XCTAssertTrue(app.staticTexts["没有正在播放的歌曲"].waitForExistence(timeout: 5), "清空后歌词面板应提示没有正在播放的歌曲")
    }

    /// 侧边菜单：定时关闭显示倒计时，取消后恢复“关”
    func testSleepTimer() {
        app.launchArguments = ["-AmplayerReset", "YES", "-AmplayerDemoPlay", "YES"]
        app.launch()
        waitForState("播放中")
        app.buttons["菜单"].tap()
        let timer = app.buttons["menu.定时关闭"]
        tapWhenReady(timer)
        tapWhenReady(app.buttons["15 分钟"])
        let countdown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "14:")).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 5) || app.staticTexts["15:00"].exists, "应显示倒计时")
        tapWhenReady(timer)
        tapWhenReady(app.buttons["取消定时"])
        XCTAssertTrue(app.staticTexts["关"].waitForExistence(timeout: 5))
    }

    /// 均衡器 AUTO 能打开和关闭
    func testEqualizerAuto() {
        app.launchArguments = ["-AmplayerReset", "YES", "-amplayer.showEQ", "YES"]
        app.launch()
        let auto = app.buttons["均衡器自动：关"]
        tapWhenReady(auto)
        XCTAssertTrue(app.buttons["均衡器自动：开"].waitForExistence(timeout: 3))
        app.buttons["均衡器自动：开"].tap()
        XCTAssertTrue(app.buttons["均衡器自动：关"].waitForExistence(timeout: 3))
    }

    /// 扫描本机文件进曲库时读标签：艺术家页能看到 m4a 标签里的“测试艺术家”
    func testLibraryScanReadsTags() {
        app.launchArguments = ["-AmplayerReset", "YES"]
        app.launch()
        app.buttons["菜单"].tap()
        tapWhenReady(app.buttons["menu.音乐来源"])
        let local = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "本机文件")).firstMatch
        waitFor(local)
        local.press(forDuration: 1.0)
        tapWhenReady(app.buttons["扫描到曲库"])
        app.buttons["完成"].firstMatch.tap()
        app.buttons["菜单"].tap()
        tapWhenReady(app.buttons["menu.曲库与播放列表"])
        tapWhenReady(app.buttons["艺术家"])
        let artist = app.staticTexts["测试艺术家"]
        XCTAssertTrue(artist.waitForExistence(timeout: 15), "扫描后艺术家页应有“测试艺术家”")
    }

    /// 音效面板：选一个预设，侧边菜单里显示它的名字
    func testSoundEffectsPreset() {
        app.launchArguments = ["-AmplayerReset", "YES", "-AmplayerDemoPlay", "YES"]
        app.launch()
        waitForState("播放中")
        app.buttons["菜单"].tap()
        tapWhenReady(app.buttons["menu.音效"])
        let ktv = app.buttons["音效：KTV"]
        tapWhenReady(ktv)
        XCTAssertTrue(ktv.isSelected, "选中的音效卡片应标记为已选")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["菜单"].tap()
        let row = app.buttons["menu.音效"]
        waitFor(row)
        XCTAssertTrue(row.label.contains("KTV"), "侧边菜单应显示当前音效：\(row.label)")
        // 恢复原声，免得影响其它测试
        row.tap()
        tapWhenReady(app.buttons["音效：原声"])
        app.buttons["完成"].firstMatch.tap()
    }
}
