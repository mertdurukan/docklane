import CoreGraphics
import XCTest
@testable import DocklaneCore

private func window(
    _ id: WindowNumber,
    _ bundleID: String,
    minimized: Bool = false
) -> DockWindow {
    DockWindow(
        id: id, pid: 1, bundleID: bundleID, appName: bundleID, title: "",
        bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
        isOnScreen: !minimized, isMinimized: minimized
    )
}

private func makeRecord(
    _ id: WindowNumber,
    pid: pid_t = 10,
    title: String = "Doc",
    size: CGSize = CGSize(width: 800, height: 600),
    layer: Int = 0,
    onScreen: Bool = true
) -> WindowRecord {
    WindowRecord(id: id, pid: pid, title: title, bounds: CGRect(origin: .zero, size: size),
                 layer: layer, alpha: 1, isOnScreen: onScreen)
}

final class WindowFilterTests: XCTestCase {
    private let apps: Set<pid_t> = [10]

    func testAcceptsNormalWindow() {
        XCTAssertTrue(WindowFilter.isUserWindow(makeRecord(1), ownPID: 99, regularApps: apps))
    }

    func testRejectsOwnWindowsOtherLayersAndBackgroundApps() {
        XCTAssertFalse(WindowFilter.isUserWindow(makeRecord(1, pid: 99), ownPID: 99, regularApps: [10, 99]))
        XCTAssertFalse(WindowFilter.isUserWindow(makeRecord(1, layer: 3), ownPID: 99, regularApps: apps))
        XCTAssertFalse(WindowFilter.isUserWindow(makeRecord(1, pid: 11), ownPID: 99, regularApps: apps))
    }

    func testRejectsThinHelperStrips() {
        // Chrome's full-screen toolbar surfaces
        XCTAssertFalse(WindowFilter.isUserWindow(makeRecord(1, size: CGSize(width: 1800, height: 81)), ownPID: 99, regularApps: apps))
        XCTAssertFalse(WindowFilter.isUserWindow(makeRecord(1, size: CGSize(width: 1800, height: 149)), ownPID: 99, regularApps: apps))
    }

    func testOffScreenNeedsATitle() {
        XCTAssertTrue(WindowFilter.isUserWindow(makeRecord(1, onScreen: false), ownPID: 99, regularApps: apps))
        XCTAssertFalse(WindowFilter.isUserWindow(makeRecord(1, title: "", onScreen: false), ownPID: 99, regularApps: apps))
        XCTAssertTrue(WindowFilter.isUserWindow(makeRecord(1, title: "", onScreen: true), ownPID: 99, regularApps: apps))
    }

    func testOffScreenDuplicatesAreRemovedOnScreenKept() {
        let records = [makeRecord(1, onScreen: false), makeRecord(2, onScreen: false), makeRecord(3), makeRecord(4)]
        XCTAssertEqual(WindowFilter.removingDuplicates(records).map(\.id), [1, 3, 4])
    }
}

final class SpaceDirectoryTests: XCTestCase {
    private func space(_ id: UInt64, fullScreen: Bool = false) -> [String: Any] {
        ["ManagedSpaceID": NSNumber(value: id), "type": NSNumber(value: fullScreen ? 4 : 0)]
    }

    func testNumbersDesktopsAndMarksFullScreen() {
        let displays: [[String: Any]] = [[
            "Current Space": space(3),
            "Spaces": [space(3), space(7), space(444, fullScreen: true)],
        ]]
        let result = SpaceDirectory.placements(
            displays: displays,
            activeSpace: 3,
            windowSpaces: [100: 3, 101: 7, 102: 444, 103: 999]
        )
        XCTAssertEqual(result[100], .current)
        XCTAssertEqual(result[101], .desktop(2))
        XCTAssertEqual(result[102], .fullScreen)
        XCTAssertEqual(result[103], .current, "unknown spaces are not labelled")
    }

    func testActiveFullScreenSpaceCountsAsCurrent() {
        let displays: [[String: Any]] = [["Spaces": [space(3), space(444, fullScreen: true)]]]
        let result = SpaceDirectory.placements(displays: displays, activeSpace: 444, windowSpaces: [1: 444, 2: 3])
        XCTAssertEqual(result[1], .current)
        XCTAssertEqual(result[2], .desktop(1))
    }
}

final class DockOrderingTests: XCTestCase {
    private let chrome1 = window(1, "chrome")
    private let notes = window(2, "notes")
    private let chrome2 = window(3, "chrome")
    private let mail = window(4, "mail")

    func testGroupsByAppInFirstAppearanceOrder() {
        let result = DockOrdering.arrange([chrome1, notes, chrome2, mail], pinned: [], manualOrder: [])
        XCTAssertEqual(result.open.map(\.id), [1, 3, 2, 4])
    }

    func testPinnedAppsComeFirstInPinnedOrder() {
        let result = DockOrdering.arrange([chrome1, notes, chrome2, mail], pinned: ["mail", "notes"], manualOrder: [])
        XCTAssertEqual(result.open.map(\.id), [4, 2, 1, 3])
    }

    func testManualOrderWinsAndOthersFollow() {
        let result = DockOrdering.arrange([chrome1, notes, chrome2, mail], pinned: ["mail"], manualOrder: [3, 2])
        XCTAssertEqual(result.open.map(\.id), [3, 2, 4, 1])
    }

    func testMinimizedWindowsGetTheirOwnSection() {
        let result = DockOrdering.arrange([chrome1, window(5, "mail", minimized: true), notes], pinned: [], manualOrder: [])
        XCTAssertEqual(result.open.map(\.id), [1, 2])
        XCTAssertEqual(result.minimized.map(\.id), [5])
    }

    func testOneBadgePerApp() {
        XCTAssertEqual(DockOrdering.badgeCarriers([chrome1, notes, chrome2, mail]), [1, 2, 4])
    }
}

final class PanelLayoutTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1800, height: 1095)

    func testLeft() {
        let frames = PanelLayout.frames(edge: .left, thickness: 200, visibleFrame: visible, autoHide: false)
        XCTAssertEqual(frames.panel, CGRect(x: 0, y: 0, width: 200, height: 1095))
        XCTAssertEqual(frames.usable.minX, 200 + PanelLayout.windowGap)
        XCTAssertEqual(frames.usable.maxX, 1800)
    }

    func testRight() {
        let frames = PanelLayout.frames(edge: .right, thickness: 200, visibleFrame: visible, autoHide: false)
        XCTAssertEqual(frames.panel.minX, 1600)
        XCTAssertEqual(frames.usable.maxX, 1600 - PanelLayout.windowGap)
    }

    func testBottom() {
        let frames = PanelLayout.frames(edge: .bottom, thickness: 150, visibleFrame: visible, autoHide: false)
        XCTAssertEqual(frames.panel, CGRect(x: 0, y: 0, width: 1800, height: 150))
        XCTAssertEqual(frames.usable.minY, 150 + PanelLayout.windowGap)
    }

    func testTopSitsBelowTheMenuBar() {
        let frames = PanelLayout.frames(edge: .top, thickness: 150, visibleFrame: visible, autoHide: false)
        XCTAssertEqual(frames.panel, CGRect(x: 0, y: 945, width: 1800, height: 150))
        XCTAssertEqual(frames.usable.minY, 0)
        XCTAssertEqual(frames.usable.maxY, 945 - PanelLayout.windowGap)
        XCTAssertFalse(PanelEdge.top.isVertical)
    }

    func testTopRevealZoneIsBelowTheMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1125)
        let zone = PanelLayout.revealZone(edge: .top, screenFrame: screen, visibleFrame: visible)
        XCTAssertEqual(zone.maxY, 1095)
        XCTAssertEqual(zone.height, PanelLayout.revealDepth)
    }

    func testAutoHideReservesNothing() {
        let frames = PanelLayout.frames(edge: .left, thickness: 200, visibleFrame: visible, autoHide: true)
        XCTAssertEqual(frames.reserved, .zero)
        XCTAssertEqual(frames.usable, visible)
    }

    func testRevealZoneHugsTheEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1125)
        XCTAssertEqual(PanelLayout.revealZone(edge: .right, screenFrame: screen).minX, 1800 - PanelLayout.revealDepth)
        XCTAssertEqual(PanelLayout.revealZone(edge: .bottom, screenFrame: screen).height, PanelLayout.revealDepth)
    }

    func testPanelIsOnlyAsLongAsItsTilesCentredOnTheEdge() {
        let frames = PanelLayout.frames(edge: .left, thickness: 200, visibleFrame: visible, autoHide: true,
                                        contentLength: 300)
        let length = 300 + 2 * PanelLayout.endInset
        XCTAssertEqual(frames.panel.height, length)
        XCTAssertEqual(frames.panel.midY, visible.midY, accuracy: 1)
        XCTAssertEqual(frames.panel.width, 200)

        let bottom = PanelLayout.frames(edge: .bottom, thickness: 150, visibleFrame: visible, autoHide: true,
                                        contentLength: 600)
        XCTAssertEqual(bottom.panel.width, 600 + 2 * PanelLayout.endInset)
        XCTAssertEqual(bottom.panel.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(bottom.panel.minY, 0)
    }

    func testLongContentIsClampedToTheEdge() {
        let frames = PanelLayout.frames(edge: .bottom, thickness: 150, visibleFrame: visible, autoHide: true,
                                        contentLength: 5000)
        XCTAssertEqual(frames.panel, CGRect(x: 0, y: 0, width: 1800, height: 150))
    }

    func testWindowsStayClearOfTheWholeEdgeWhateverTheTilesLength() {
        let frames = PanelLayout.frames(edge: .left, thickness: 200, visibleFrame: visible, autoHide: false,
                                        contentLength: 300)
        XCTAssertLessThan(frames.panel.height, visible.height)
        XCTAssertEqual(frames.reserved.height, visible.height)
        XCTAssertEqual(frames.usable.minX, 200 + PanelLayout.windowGap)
    }

    func testRevealZoneCoversOnlyThePanelsStretch() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1125)
        let panel = CGRect(x: 0, y: 400, width: 200, height: 300)
        let zone = PanelLayout.revealZone(edge: .left, screenFrame: screen, panel: panel)
        XCTAssertEqual(zone, CGRect(x: 0, y: 400, width: PanelLayout.revealDepth, height: 300))
        XCTAssertFalse(zone.contains(CGPoint(x: 1, y: 100)))
        XCTAssertTrue(zone.contains(CGPoint(x: 3, y: 500)))
    }

    func testRevealedPanelStaysAtLeastTheMinimumThenHidesAfterTheDelay() {
        let revealed = Date(timeIntervalSinceReferenceDate: 0)
        // Pointer leaves right away: the minimum wins.
        XCTAssertEqual(PanelLayout.hideDeadline(revealedAt: revealed, leftAt: revealed.addingTimeInterval(0.5),
                                                minimumVisible: 2, delay: 0.4),
                       revealed.addingTimeInterval(2))
        // Pointer leaves after the minimum: the usual delay applies.
        XCTAssertEqual(PanelLayout.hideDeadline(revealedAt: revealed, leftAt: revealed.addingTimeInterval(5),
                                                minimumVisible: 2, delay: 0.4),
                       revealed.addingTimeInterval(5.4))
    }
}

final class PanelMetricsTests: XCTestCase {
    func testSizeSliderRangeAndClamping() {
        XCTAssertEqual(PanelMetrics(size: 0).tileWidth, 120)
        XCTAssertEqual(PanelMetrics(size: 1).tileWidth, 360)
        XCTAssertEqual(PanelMetrics(size: -5), PanelMetrics(size: 0))
        XCTAssertEqual(PanelMetrics(size: 5), PanelMetrics(size: 1))
    }

    func testThicknessIncludesInsets() {
        let metrics = PanelMetrics(size: 0)
        let insets = 2 * (PanelMetrics.edgeInset + PanelMetrics.tileInset)
        XCTAssertEqual(metrics.thickness(for: .left), metrics.tileWidth + insets)
        XCTAssertEqual(metrics.thickness(for: .bottom), metrics.tileHeight + insets)
    }

    func testTileKeepsAspectRatioWithinBounds() {
        let metrics = PanelMetrics(size: 0.5)
        let wide = metrics.tileSize(imageSize: CGSize(width: 1600, height: 900), edge: .left)
        XCTAssertEqual(wide.width, metrics.tileWidth)
        XCTAssertEqual(wide.height, (metrics.tileWidth * 900 / 1600).rounded())
        let veryTall = metrics.tileSize(imageSize: CGSize(width: 100, height: 1000), edge: .left)
        XCTAssertEqual(veryTall.height, (metrics.tileWidth * 1.1).rounded(), "clamped")
        let bottom = metrics.tileSize(imageSize: CGSize(width: 1600, height: 900), edge: .bottom)
        XCTAssertEqual(bottom.height, metrics.tileHeight)
    }
}

final class CaptureGeometryTests: XCTestCase {
    func testFittedSizeKeepsAspectAndNeverUpscales() {
        XCTAssertEqual(WindowCapturer.fittedSize(for: CGSize(width: 1800, height: 1000), within: CGSize(width: 480, height: 320)),
                       CGSize(width: 480, height: 267))
        XCTAssertEqual(WindowCapturer.fittedSize(for: CGSize(width: 200, height: 100), within: CGSize(width: 480, height: 320)),
                       CGSize(width: 200, height: 100))
    }

    func testFingerprintIsStableAndSensitive() throws {
        func solid(_ gray: CGFloat) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            return try XCTUnwrap(context.makeImage())
        }
        XCTAssertEqual(ImageFingerprint.of(try solid(0.2)), ImageFingerprint.of(try solid(0.2)))
        XCTAssertNotEqual(ImageFingerprint.of(try solid(0.2)), ImageFingerprint.of(try solid(0.8)))
    }
}

final class LayoutMemoryTests: XCTestCase {
    func testLabelAppliesOnlyToTheSameApp() {
        var memory = LayoutMemory()
        memory.setLabel("Work", for: window(7, "chrome"))
        XCTAssertEqual(memory.label(for: window(7, "chrome")), "Work")
        XCTAssertNil(memory.label(for: window(7, "mail")), "reused window number, different app")
        memory.setLabel("  ", for: window(7, "chrome"))
        XCTAssertNil(memory.label(for: window(7, "chrome")), "blank label clears it")
    }

    func testMoveAndForget() {
        var memory = LayoutMemory()
        memory.move(3, before: 1, currentOrder: [1, 2, 3])
        XCTAssertEqual(memory.manualOrder, [3, 1, 2])
        memory.move(3, before: nil, currentOrder: memory.manualOrder)
        XCTAssertEqual(memory.manualOrder, [1, 2, 3])
        memory.forget([2])
        XCTAssertEqual(memory.manualOrder, [1, 3])
    }

    func testRoundTripAndFutureVersionIgnored() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DocklaneTests-\(UUID().uuidString)"))
        var memory = LayoutMemory()
        memory.setLabel("Notes", for: window(9, "notes"))
        memory.move(9, before: nil, currentOrder: [4])
        memory.save(to: defaults, key: "layout")
        XCTAssertEqual(LayoutMemory.load(from: defaults, key: "layout"), memory)

        var future = memory
        future.version = LayoutMemory.currentVersion + 1
        future.save(to: defaults, key: "layout")
        XCTAssertEqual(LayoutMemory.load(from: defaults, key: "layout"), LayoutMemory(), "unknown format → start fresh")
    }
}

final class WindowPlacementTests: XCTestCase {
    private let area = CGRect(x: 100, y: 0, width: 1600, height: 1000)

    func testHalves() {
        let current = CGRect(x: 300, y: 300, width: 800, height: 600)
        XCTAssertEqual(PlacementPreset.leftHalf.frame(in: area, current: current), CGRect(x: 100, y: 0, width: 800, height: 1000))
        XCTAssertEqual(PlacementPreset.rightHalf.frame(in: area, current: current), CGRect(x: 900, y: 0, width: 800, height: 1000))
        XCTAssertEqual(PlacementPreset.topHalf.frame(in: area, current: current), CGRect(x: 100, y: 500, width: 1600, height: 500))
        XCTAssertEqual(PlacementPreset.bottomHalf.frame(in: area, current: current), CGRect(x: 100, y: 0, width: 1600, height: 500))
        XCTAssertEqual(PlacementPreset.fill.frame(in: area, current: current), area)
    }

    func testCenterKeepsSizeWhenItFits() {
        let centered = PlacementPreset.center.frame(in: area, current: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(centered, CGRect(x: 500, y: 200, width: 800, height: 600))
        let tooBig = PlacementPreset.center.frame(in: area, current: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        XCTAssertEqual(tooBig.size, CGSize(width: 1120, height: 700))
    }
}

final class WorkspaceTests: XCTestCase {
    private func live(_ id: WindowNumber, _ bundleID: String, _ title: String) -> DockWindow {
        DockWindow(id: id, pid: 1, bundleID: bundleID, appName: bundleID, title: title,
                   bounds: .zero, isOnScreen: true)
    }

    private func saved(_ bundleID: String, _ title: String) -> SavedWindow {
        SavedWindow(bundleID: bundleID, appName: bundleID, title: title, frame: .zero)
    }

    func testExactTitlesFirstThenRemainingWindowsOfTheApp() {
        let pairs = WorkspaceMatcher.match(
            saved: [saved("chrome", "Mail"), saved("chrome", "Docs"), saved("notes", "Ideas")],
            live: [live(1, "chrome", "Docs"), live(2, "chrome", "News"), live(3, "notes", "Other")]
        )
        let mapping = Dictionary(uniqueKeysWithValues: pairs.map { ($0.saved.title, $0.window.id) })
        XCTAssertEqual(mapping["Docs"], 1, "exact title")
        XCTAssertEqual(mapping["Mail"], 2, "leftover chrome window")
        XCTAssertEqual(mapping["Ideas"], 3, "only notes window")
    }

    func testEachLiveWindowUsedOnceAndMissingAppsSkipped() {
        let pairs = WorkspaceMatcher.match(saved: [saved("chrome", "A"), saved("chrome", "B"), saved("mail", "C")],
                                           live: [live(1, "chrome", "X")])
        XCTAssertEqual(pairs.count, 1)
    }

    func testProfileListsAppsOnce() {
        let profile = WorkspaceProfile(name: "Work", windows: [saved("a", "1"), saved("b", "2"), saved("a", "3")])
        XCTAssertEqual(profile.bundleIDs, ["a", "b"])
    }

    func testLibraryRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DocklaneTests-\(UUID().uuidString)"))
        var library = WorkspaceLibrary()
        library.profiles = [WorkspaceProfile(name: "Study", windows: [saved("notes", "N")])]
        library.save(to: defaults, key: "ws")
        XCTAssertEqual(WorkspaceLibrary.load(from: defaults, key: "ws"), library)
    }
}

final class AudioAndSearchTests: XCTestCase {
    func testHelperProcessCountsForItsApp() {
        let playing: Set<String> = ["com.google.Chrome.helper", "com.spotify.client"]
        XCTAssertTrue(AudioActivity.isPlaying("com.google.Chrome", in: playing))
        XCTAssertTrue(AudioActivity.isPlaying("com.spotify.client", in: playing))
        XCTAssertFalse(AudioActivity.isPlaying("com.google.Chrome.canary", in: ["com.google.Chrome"]))
        XCTAssertFalse(AudioActivity.isPlaying("", in: playing))
    }

    func testSearchIgnoresCaseDiacriticsAndWordOrder() {
        let window = DockWindow(id: 1, pid: 1, bundleID: "chrome", appName: "Google Chrome",
                                title: "ÇALIŞMA_REHBERİ notes", bounds: .zero, isOnScreen: true)
        XCTAssertTrue(WindowSearch.matches(window, label: nil, query: "calisma"))
        XCTAssertTrue(WindowSearch.matches(window, label: nil, query: "rehberi chrome"))
        XCTAssertTrue(WindowSearch.matches(window, label: "Tez", query: "tez"))
        XCTAssertFalse(WindowSearch.matches(window, label: nil, query: "netflix"))
        XCTAssertTrue(WindowSearch.matches(window, label: nil, query: "  "))
    }
}

final class LanguageCodeTests: XCTestCase {
    let available = ["en", "tr", "zh-Hans", "pt", "ar"]

    func testExactAndRegionalCodesMatch() {
        XCTAssertEqual(LanguageCode.match("tr", in: available), "tr")
        XCTAssertEqual(LanguageCode.match("pt-BR", in: available), "pt")
        XCTAssertEqual(LanguageCode.match("zh-Hans-CN", in: available), "zh-Hans")
        XCTAssertEqual(LanguageCode.match("en-GB", in: available), "en")
    }

    func testDifferentScriptsAndPrefixLookalikesDoNotMatch() {
        XCTAssertNil(LanguageCode.match("zh-Hant", in: available))
        XCTAssertNil(LanguageCode.match("ta", in: available))
        XCTAssertNil(LanguageCode.match("arn", in: available))
    }
}

/// Every string in the catalog is translated into every language, with the same placeholders.
final class LocalizationCatalogTests: XCTestCase {
    static let languages = ["ar", "bn", "es", "fr", "hi", "id", "pt", "ru", "tr", "zh-Hans"]

    func testEveryStringIsTranslatedWithMatchingPlaceholders() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertFalse(strings.isEmpty)

        func placeholders(_ text: String) -> [String] {
            text.matches(of: /%(lld|@)/).map { String($0.output.0) }.sorted()
        }
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                let localization = localizations[language]
                let unit = localization?["stringUnit"] as? [String: String]
                var value = try XCTUnwrap(unit?["value"], "\(key) has no \(language) translation")
                // Plural substitutions: "%#@windows@" stands for its argument's format specifier.
                let substitutions = localization?["substitutions"] as? [String: [String: Any]] ?? [:]
                for (name, substitution) in substitutions {
                    let specifier = try XCTUnwrap(substitution["formatSpecifier"] as? String)
                    value = value.replacingOccurrences(of: "%#@\(name)@", with: "%" + specifier)
                }
                XCTAssertFalse(value.isEmpty, "\(key) is empty in \(language)")
                XCTAssertEqual(placeholders(value), placeholders(key), "\(key) placeholders differ in \(language)")
            }
        }
    }
}

final class HintTextTests: XCTestCase {
    func testItemsStayTogetherAndBreaksFallAfterTheDot() {
        let text = HintText.wrappingBetweenItems("Tab next  ·  / search  ·  Esc cancel")
        XCTAssertEqual(text, "Tab\u{00A0}next\u{00A0}·  /\u{00A0}search\u{00A0}·  Esc\u{00A0}cancel")
        // The only ordinary spaces are the break points after each dot.
        XCTAssertEqual(text.components(separatedBy: " ").filter { !$0.isEmpty }.count, 3)
    }

    func testTextWithoutSeparatorsIsOneUnbreakableItem() {
        XCTAssertEqual(HintText.wrappingBetweenItems("Return switch"), "Return\u{00A0}switch")
    }
}

final class SwitcherStartTests: XCTestCase {
    private func win(_ id: WindowNumber, pid: pid_t, minimized: Bool = false) -> DockWindow {
        DockWindow(id: id, pid: pid, bundleID: "app\(pid)", appName: "App \(pid)", title: "",
                   bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                   isOnScreen: !minimized, isMinimized: minimized)
    }

    func testFirstPressSelectsTheNextApp() {
        let items = [win(1, pid: 10), win(2, pid: 20), win(3, pid: 30)]
        let result = SwitcherStart.arrange(items, current: 1, frontPID: 10, reverse: false)
        XCTAssertEqual(result.items.map(\.id), [1, 2, 3])
        XCTAssertEqual(result.selection, 1)
    }

    func testStaleRecentListStillStartsFromTheFocusedWindow() {
        // The focused window (3) was not yet recorded as most recent.
        let items = [win(1, pid: 10), win(2, pid: 20), win(3, pid: 30)]
        let result = SwitcherStart.arrange(items, current: 3, frontPID: 30, reverse: false)
        XCTAssertEqual(result.items.map(\.id), [3, 1, 2])
        XCTAssertEqual(result.items[result.selection].id, 1)
    }

    func testOtherWindowsOfTheSameAppAreSkippedOnFirstPress() {
        let items = [win(1, pid: 10), win(2, pid: 10), win(3, pid: 30)]
        let result = SwitcherStart.arrange(items, current: 1, frontPID: 10, reverse: false)
        XCTAssertEqual(result.items[result.selection].id, 3)
    }

    func testSingleAppFallsBackToItsNextWindow() {
        let items = [win(1, pid: 10), win(2, pid: 10)]
        XCTAssertEqual(SwitcherStart.arrange(items, current: 1, frontPID: 10, reverse: false).selection, 1)
    }

    func testMinimizedWindowsOfOtherAppsAreNotTheFirstTarget() {
        let items = [win(1, pid: 10), win(2, pid: 10), win(3, pid: 30, minimized: true)]
        XCTAssertEqual(SwitcherStart.arrange(items, current: 1, frontPID: 10, reverse: false).selection, 1)
    }

    func testNothingFocusedSelectsTheFirstWindow() {
        // Desktop or an app without windows is in front: the first window is the target.
        let items = [win(1, pid: 10), win(2, pid: 20)]
        XCTAssertEqual(SwitcherStart.arrange(items, current: nil, frontPID: 99, reverse: false).selection, 0)
        XCTAssertEqual(SwitcherStart.arrange(items, current: nil, frontPID: nil, reverse: false).selection, 0)
    }

    func testFrontAppWithoutFocusedWindowStillCountsAsHere() {
        let items = [win(1, pid: 10), win(2, pid: 20)]
        XCTAssertEqual(SwitcherStart.arrange(items, current: nil, frontPID: 10, reverse: false).selection, 1)
    }

    func testReverseSelectsTheLastItem() {
        let items = [win(1, pid: 10), win(2, pid: 20), win(3, pid: 30)]
        XCTAssertEqual(SwitcherStart.arrange(items, current: 1, frontPID: 10, reverse: true).selection, 2)
        XCTAssertEqual(SwitcherStart.arrange([win(1, pid: 10)], current: 1, frontPID: 10, reverse: false).selection, 0)
    }
}
