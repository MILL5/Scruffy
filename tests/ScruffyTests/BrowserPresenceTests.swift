import XCTest
@testable import Scruffy

final class BrowserPresenceTests: XCTestCase {
    private let mainBrowserIDs = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"
    ]

    @MainActor
    func testSupportedRegularMainBrowsersRequireQuit() {
        for id in mainBrowserIDs {
            XCTAssertTrue(AppModel.isRunningBrowser(bundleIdentifier: id, isRegularApplication: true, isTerminated: false), id)
        }
    }

    @MainActor
    func testHelperOnlyInventoryDoesNotRequireQuit() {
        let helperIDs = [
            "com.google.Chrome.helper", "com.google.Chrome.helper.GPU", "com.google.Chrome.helper.renderer",
            "com.microsoft.edgemac.helper.Renderer", "com.brave.Browser.helper", "company.thebrowser.Browser.helper",
            "org.mozilla.firefox.helper", "com.apple.WebKit.WebContent", "com.apple.WebKit.GPU", "com.apple.WebKit.Networking"
        ]
        XCTAssertFalse(helperIDs.contains {
            AppModel.isRunningBrowser(bundleIdentifier: $0, isRegularApplication: true, isTerminated: false)
        })
        for id in helperIDs {
            XCTAssertFalse(AppModel.isRunningBrowser(bundleIdentifier: id, isRegularApplication: true, isTerminated: false), id)
        }
    }

    @MainActor
    func testNonRegularAndTerminatedBrowsersDoNotRequireQuit() {
        for id in mainBrowserIDs {
            XCTAssertFalse(AppModel.isRunningBrowser(bundleIdentifier: id, isRegularApplication: false, isTerminated: false), id)
            XCTAssertFalse(AppModel.isRunningBrowser(bundleIdentifier: id, isRegularApplication: true, isTerminated: true), id)
            XCTAssertFalse(AppModel.isRunningBrowser(bundleIdentifier: id, isRegularApplication: false, isTerminated: true), id)
        }
    }

    @MainActor
    func testUnknownOrEmptyIdentifiersDoNotRequireQuit() {
        for id in ["", "com.richcrane.scruffy", "com.jetbrains.rider", "com.apple.finder"] {
            XCTAssertFalse(AppModel.isRunningBrowser(bundleIdentifier: id, isRegularApplication: true, isTerminated: false), id)
        }
        let emptyInventory: [String] = []
        XCTAssertFalse(emptyInventory.contains {
            AppModel.isRunningBrowser(bundleIdentifier: $0, isRegularApplication: true, isTerminated: false)
        })
    }

    @MainActor
    func testSupportedRegularVariantsStillRequireQuit() {
        for id in ["com.google.Chrome.canary", "org.mozilla.firefox.nightly", "com.microsoft.edgemac.Dev", "com.brave.Browser.nightly"] {
            XCTAssertTrue(AppModel.isRunningBrowser(bundleIdentifier: id, isRegularApplication: true, isTerminated: false), id)
        }
    }
}
