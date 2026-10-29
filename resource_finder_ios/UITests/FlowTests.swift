import XCTest

final class FlowTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.textFields["search_field"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .portrait
    }
    private func search() {
        let field = app.textFields["search_field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("测试")
        app.buttons["search_submit"].tap()
        XCTAssertTrue(app.buttons["work_10"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testNormalLaunchStartsOutsideFixtureMode() {
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.textFields["search_field"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["work_10"].exists)
        screenshot("00-normal-launch")
    }
    func testSearchLineSelectionAndActualVideoPlayback() {
        search(); screenshot("01-search")
        app.buttons["work_10"].tap()
        XCTAssertTrue(app.buttons["episode_1"].waitForExistence(timeout: 10))
        app.buttons["line_cz"].tap()
        XCTAssertTrue(app.buttons["episode_special"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["episode_1"].exists)
        app.buttons["line_xl"].tap()
        XCTAssertTrue(app.buttons["episode_1"].waitForExistence(timeout: 5))
        screenshot("02-detail")
        app.buttons["episode_1"].tap()
        let decode = app.staticTexts["decode_check"]
        expectation(for: NSPredicate(format: "label == %@", "已解码并推进"), evaluatedWith: decode)
        waitForExpectations(timeout: 15)
        screenshot("03-player-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let landscape = XCUIScreen.main.screenshot()
        XCTAssertGreaterThan(landscape.image.size.width, landscape.image.size.height)
        screenshot("04-player-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["close_player"].waitForExistence(timeout: 5))
        app.buttons["close_player"].tap()
        XCTAssertTrue(app.buttons["episode_1"].waitForExistence(timeout: 5))
    }
    func testSearchHistoryCanBeCleared() {
        search(); app.tabBars.buttons["历史"].tap()
        XCTAssertTrue(app.buttons["清空记录"].waitForExistence(timeout: 5))
        app.buttons["清空记录"].tap(); app.buttons["确认清空"].tap()
        XCTAssertTrue(app.staticTexts["暂无搜索记录"].waitForExistence(timeout: 5))
        screenshot("05-history-cleared")
    }
    func testDownloadOnlyThenRelaunchAndOfflinePlay() {
        search(); app.buttons["work_10"].tap()
        XCTAssertTrue(app.buttons["download_only"].waitForExistence(timeout: 10))
        app.buttons["download_only"].tap()
        XCTAssertTrue(app.buttons["choose_1"].waitForExistence(timeout: 5))
        app.buttons["choose_1"].tap(); app.buttons["confirm_download"].tap()
        XCTAssertTrue(app.alerts["下载任务"].waitForExistence(timeout: 5)); app.alerts.buttons["好"].tap()
        XCTAssertFalse(app.buttons["close_player"].exists)
        app.tabBars.buttons["下载"].tap()
        let state = app.staticTexts["download_state_1"]
        expectation(for: NSPredicate(format: "label == %@", "已下载"), evaluatedWith: state)
        waitForExpectations(timeout: 60)
        screenshot("06-download-complete")
        app.terminate(); app.launchArguments = ["--ui-testing", "--keep-downloads"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["下载"].waitForExistence(timeout: 10)); app.tabBars.buttons["下载"].tap()
        XCTAssertTrue(app.buttons["离线播放"].waitForExistence(timeout: 5)); app.buttons["离线播放"].tap()
        expectation(for: NSPredicate(format: "label == %@", "已解码并推进"), evaluatedWith: app.staticTexts["decode_check"])
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts["离线观看"].exists)
        screenshot("07-offline-playback")
        app.buttons["close_player"].tap()
        app.buttons["删除"].firstMatch.tap(); app.buttons["确认删除"].tap()
        XCTAssertTrue(app.staticTexts["暂无下载"].waitForExistence(timeout: 5))
    }
    func testNaturalEndAutomaticallyStartsNextEpisode() {
        search(); app.buttons["work_10"].tap()
        XCTAssertTrue(app.buttons["episode_1"].waitForExistence(timeout: 10)); app.buttons["episode_1"].tap()
        let toggle = app.switches["自动下一集"]
        if toggle.waitForExistence(timeout: 5), toggle.value as? String == "0" { toggle.tap() }
        expectation(for: NSPredicate(format: "label == %@", "第2集"), evaluatedWith: app.staticTexts["playing_episode"])
        waitForExpectations(timeout: 35)
        expectation(for: NSPredicate(format: "label == %@", "已解码并推进"), evaluatedWith: app.staticTexts["decode_check"])
        waitForExpectations(timeout: 10)
        screenshot("08-auto-next")
    }
    func testFavoriteCanBeAddedAndRemoved() {
        search(); app.buttons["work_10"].tap()
        XCTAssertTrue(app.buttons["收藏影片"].waitForExistence(timeout: 5))
        app.buttons["收藏影片"].tap()
        XCTAssertTrue(app.buttons["取消收藏"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["测试影片"].waitForExistence(timeout: 5))
        app.staticTexts["测试影片"].tap()
        app.buttons["取消收藏"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["还没有收藏"].waitForExistence(timeout: 5))
    }
}
