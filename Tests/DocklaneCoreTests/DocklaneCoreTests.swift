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
        XCTAssertEqual(WindowFilter.resolving(records, located: [1, 2, 3, 4], minimized: []).map(\.id), [1, 3, 4])
    }

    func testSameTitleAtDifferentPositionsAreTwoWindows() {
        let first = makeRecord(1, title: "New Incognito Tab", onScreen: false)
        let second = WindowRecord(id: 2, pid: 10, title: "New Incognito Tab",
                                  bounds: CGRect(x: 22, y: 22, width: 800, height: 600),
                                  layer: 0, alpha: 1, isOnScreen: false)
        XCTAssertEqual(WindowFilter.resolving([first, second], located: [1, 2], minimized: []).map(\.id), [1, 2])
    }

    func testOffScreenWindowOnNoSpaceIsAGhost() {
        let records = [makeRecord(1, onScreen: false), makeRecord(2, onScreen: false), makeRecord(3)]
        XCTAssertEqual(WindowFilter.resolving(records, located: [2], minimized: []).map(\.id), [2, 3],
                       "closed window 1 lingers on no space; on-screen 3 needs no space")
    }

    func testGhostTwinDoesNotReplaceTheRealWindow() {
        // A full-screen app reports its window twice; the first copy is on no space.
        let ghost = makeRecord(1, onScreen: false)
        let real = makeRecord(2, onScreen: false)
        XCTAssertEqual(WindowFilter.resolving([ghost, real], located: [2], minimized: []).map(\.id), [2])
    }

    func testMinimizedWindowsAndUnknownSpacesAreKept() {
        let records = [makeRecord(1, onScreen: false), makeRecord(2, title: "Other", onScreen: false)]
        XCTAssertEqual(WindowFilter.resolving(records, located: [], minimized: [1]).map(\.id), [1])
        XCTAssertEqual(WindowFilter.resolving(records, located: nil, minimized: []).map(\.id), [1, 2])
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
            windowSpaces: [100: [3], 101: [7], 102: [444], 103: [999], 104: []]
        )
        XCTAssertEqual(result[100], .current)
        XCTAssertEqual(result[101], .desktop(2))
        XCTAssertEqual(result[102], .fullScreen)
        XCTAssertEqual(result[103], .current, "unknown spaces are not labelled")
        XCTAssertNil(result[104], "windows on no space are left out")
    }

    func testActiveFullScreenSpaceCountsAsCurrent() {
        let displays: [[String: Any]] = [["Spaces": [space(3), space(444, fullScreen: true)]]]
        let result = SpaceDirectory.placements(displays: displays, activeSpace: 444, windowSpaces: [1: [444], 2: [3]])
        XCTAssertEqual(result[1], .current)
        XCTAssertEqual(result[2], .desktop(1))
    }

    func testWindowOnAllDesktopsIsCurrent() {
        let displays: [[String: Any]] = [["Current Space": space(3), "Spaces": [space(3), space(7)]]]
        let result = SpaceDirectory.placements(displays: displays, activeSpace: 3, windowSpaces: [1: [7, 3], 2: [7]])
        XCTAssertEqual(result[1], .current)
        XCTAssertEqual(result[2], .desktop(2))
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

    func testTopPanelAlsoRevealsAtTheVeryTopAboveItself() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1125)
        let panel = CGRect(x: 700, y: 900, width: 400, height: 195)
        let zones = PanelLayout.revealZones(edge: .top, screenFrame: screen, visibleFrame: visible, panel: panel)
        XCTAssertEqual(zones.count, 2)
        XCTAssertTrue(zones.contains { $0.contains(CGPoint(x: 900, y: 1124)) }, "pointer stopped at the top")
        XCTAssertTrue(zones.contains { $0.contains(CGPoint(x: 900, y: 1125)) }, "topmost row reports y == maxY")
        XCTAssertTrue(zones.contains { $0.contains(CGPoint(x: 900, y: 1093)) }, "strip below the menu bar")
        XCTAssertFalse(zones.contains { $0.contains(CGPoint(x: 900, y: 1110) )}, "middle of the menu bar")
        XCTAssertFalse(zones.contains { $0.contains(CGPoint(x: 100, y: 1124)) }, "menus left of the panel")
    }

    func testOtherEdgesAndHiddenMenuBarHaveOneZone() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1125)
        XCTAssertEqual(PanelLayout.revealZones(edge: .left, screenFrame: screen, visibleFrame: visible).count, 1)
        XCTAssertEqual(PanelLayout.revealZones(edge: .top, screenFrame: screen, visibleFrame: screen).count, 1)
        let noMenuBar = PanelLayout.revealZones(edge: .top, screenFrame: screen, visibleFrame: screen)
        XCTAssertTrue(noMenuBar[0].contains(CGPoint(x: 900, y: 1125)))
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
        let far = PanelMetrics.edgeInset + PanelMetrics.tileInset
        XCTAssertEqual(metrics.thickness(for: .top), metrics.tileHeight + PanelMetrics.edgeGap + far)
        XCTAssertEqual(metrics.thickness(for: .right), metrics.tileWidth + PanelMetrics.edgeGap + far)
        // The app icon overhangs the bottom-left corner, which faces the left and bottom edges.
        XCTAssertEqual(metrics.thickness(for: .left), metrics.tileWidth + PanelMetrics.edgeGap + metrics.iconOverhang + far)
        XCTAssertEqual(metrics.thickness(for: .bottom, background: true),
                       metrics.tileHeight + PanelMetrics.edgeGap + metrics.iconOverhang + PanelMetrics.tileInset + far)
    }

    func testEdgeGapIsMinimal() {
        XCTAssertEqual(PanelMetrics(size: 0.3).edgeSideInset(for: .top), 4, "like the Dock")
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

final class ThumbnailSizeTests: XCTestCase {
    private let card = CGSize(width: 216, height: 135)

    func testTypicalWindowIsCapturedAtTileSizeNotMore() {
        let metrics = PanelMetrics(size: 0.4)  // tiles 216 pt wide
        let size = metrics.thumbnailPixelSize(for: CGSize(width: 1400, height: 1000), edge: .left,
                                              scale: 1, otherImage: card)
        XCTAssertEqual(size, CGSize(width: 216, height: 155))
    }

    func testSmallTilesStillFillTheSwitcherCard() {
        let metrics = PanelMetrics(size: 0)  // tiles 120 pt wide
        let size = metrics.thumbnailPixelSize(for: CGSize(width: 1600, height: 1000), edge: .left,
                                              scale: 1, otherImage: card)
        XCTAssertEqual(size, CGSize(width: 216, height: 135))
    }

    func testRetinaDoublesThePixels() {
        let metrics = PanelMetrics(size: 0.4)
        let size = metrics.thumbnailPixelSize(for: CGSize(width: 1400, height: 1000), edge: .left,
                                              scale: 2, otherImage: card)
        XCTAssertEqual(size, CGSize(width: 432, height: 309))
    }

    func testEveryTileAndCardIsCoveredForAnyShape() {
        for step in 0...10 {
            let metrics = PanelMetrics(size: Double(step) / 10)
            for edge in PanelEdge.allCases {
                for ratio in [0.15, 0.4, 0.6, 1.0, 1.1, 2.5] {
                    let source = CGSize(width: 3000, height: 3000 * ratio)
                    let pixels = metrics.thumbnailPixelSize(for: source, edge: edge, scale: 1, otherImage: card)
                    let tile = metrics.tileSize(imageSize: source, edge: edge)
                    XCTAssertGreaterThanOrEqual(pixels.width, tile.width, "\(edge) \(step) \(ratio)")
                    XCTAssertGreaterThanOrEqual(pixels.height, tile.height, "\(edge) \(step) \(ratio)")
                    XCTAssertGreaterThanOrEqual(pixels.width, card.width, "\(edge) \(step) \(ratio)")
                    XCTAssertGreaterThanOrEqual(pixels.height, card.height, "\(edge) \(step) \(ratio)")
                }
            }
        }
    }
}

final class SwitcherKeysTests: XCTestCase {
    private func press(_ special: SwitcherKeyPress.Special? = nil, _ character: String? = nil,
                       base: String? = nil, text: String? = nil, held: Bool = true,
                       shift: Bool = false, other: Bool = false) -> SwitcherKeyPress {
        SwitcherKeyPress(special: special, character: character, baseCharacter: base ?? character,
                         text: text ?? character, triggerHeld: held, shift: shift, otherModifier: other)
    }

    func testTabWithTriggerOpensAndMoves() {
        XCTAssertEqual(SwitcherKeys.decide(press(.tab), isOpen: false, isSearching: false), .handle(.next))
        XCTAssertEqual(SwitcherKeys.decide(press(.tab, shift: true), isOpen: false, isSearching: false), .handle(.previous))
        XCTAssertEqual(SwitcherKeys.decide(press(.tab, other: true), isOpen: false, isSearching: false), .pass)
        XCTAssertEqual(SwitcherKeys.decide(press(.tab, held: false), isOpen: false, isSearching: false), .pass)
    }

    func testClosedSwitcherLetsEverythingThrough() {
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "q"), isOpen: false, isSearching: false), .pass)
        XCTAssertEqual(SwitcherKeys.decide(press(.escape), isOpen: false, isSearching: false), .pass)
    }

    func testLetterShortcutsNeedTheTriggerHeld() {
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "q"), isOpen: true, isSearching: false), .handle(.quitApp))
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "q", held: false), isOpen: true, isSearching: false),
                       .releaseAndPass, "⌘ was released but the event was missed: never quit")
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "w", other: true), isOpen: true, isSearching: false), .swallow)
    }

    func testShortcutsFollowTheLayoutNotTheKeyPosition() {
        // Turkish Q: "/" is Shift+7, and the ANSI slash key types ".".
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "/", base: "7", shift: true), isOpen: true, isSearching: false),
                       .handle(.beginSearch))
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "."), isOpen: true, isSearching: false), .handle(.cancel),
                       "the key typing \".\" is ⌘. (cancel) wherever it is")
        // AZERTY: the key at the ANSI "Q" position types "a"; the real "q" quits.
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "a"), isOpen: true, isSearching: false), .swallow)
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "Q", base: "q", shift: true), isOpen: true, isSearching: false),
                       .handle(.quitApp))
    }

    func testSystemSwitcherConventions() {
        let back = SwitcherKeyPress(special: .backquote, triggerHeld: true)
        XCTAssertEqual(SwitcherKeys.decide(back, isOpen: true, isSearching: false), .handle(.previous))
        let forward = SwitcherKeyPress(special: .backquote, triggerHeld: true, shift: true)
        XCTAssertEqual(SwitcherKeys.decide(forward, isOpen: true, isSearching: false), .handle(.next))
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "."), isOpen: true, isSearching: false), .handle(.cancel))
    }

    func testNumbersGoToSpaces() {
        let two = SwitcherKeyPress(digit: 2, character: "2", baseCharacter: "2", text: "2", triggerHeld: true)
        XCTAssertEqual(SwitcherKeys.decide(two, isOpen: true, isSearching: false), .handle(.goToSpace(2)))
        XCTAssertEqual(SwitcherKeys.decide(two, isOpen: true, isSearching: true), .handle(.character("2")),
                       "digits are text while searching")
        XCTAssertEqual(SwitcherKeys.decide(two, isOpen: false, isSearching: false), .pass)
        // AZERTY number row types "é" without Shift; the position still means desktop 2.
        let azerty = SwitcherKeyPress(digit: 2, character: "é", baseCharacter: "é", triggerHeld: true)
        XCTAssertEqual(SwitcherKeys.decide(azerty, isOpen: true, isSearching: false), .handle(.goToSpace(2)))
    }

    func testCommandFStartsSearchOnAnyLayout() {
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "f"), isOpen: true, isSearching: false), .handle(.beginSearch))
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "F", base: "f", shift: true), isOpen: true, isSearching: false),
                       .handle(.beginSearch))
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "f", held: false), isOpen: true, isSearching: false), .releaseAndPass)
    }

    func testSearchTypesTextWithoutTheModifier() {
        XCTAssertEqual(SwitcherKeys.decide(press(nil, "q", text: "й", held: false), isOpen: true, isSearching: true),
                       .handle(.character("й")))
        XCTAssertEqual(SwitcherKeys.decide(press(.delete, held: false), isOpen: true, isSearching: true), .handle(.backspace))
        XCTAssertEqual(SwitcherKeys.decide(press(.escape, held: false), isOpen: true, isSearching: true), .handle(.cancel))
        XCTAssertEqual(SwitcherKeys.decide(press(nil, nil, held: false), isOpen: true, isSearching: true), .swallow)
    }

    func testNavigationKeys() {
        XCTAssertEqual(SwitcherKeys.decide(press(.left), isOpen: true, isSearching: false), .handle(.left))
        XCTAssertEqual(SwitcherKeys.decide(press(.returnKey), isOpen: true, isSearching: false), .handle(.confirm))
        XCTAssertEqual(SwitcherKeys.decide(press(.space), isOpen: true, isSearching: false), .handle(.confirm))
    }

    func testModifierRelease() {
        XCTAssertTrue(SwitcherKeys.modifierReleased(triggerHeld: false, isOpen: true, isSearching: false))
        XCTAssertFalse(SwitcherKeys.modifierReleased(triggerHeld: false, isOpen: true, isSearching: true))
        XCTAssertFalse(SwitcherKeys.modifierReleased(triggerHeld: true, isOpen: true, isSearching: false))
        XCTAssertFalse(SwitcherKeys.modifierReleased(triggerHeld: false, isOpen: false, isSearching: false))
    }
}

final class SpaceNavigationTests: XCTestCase {
    private let desktop1 = SpaceInfo(id: 3, isFullScreen: false, desktopNumber: 1, display: "A", isShown: false)
    private let claude = SpaceInfo(id: 681, isFullScreen: true, desktopNumber: nil, display: "A", isShown: false)
    private let chrome = SpaceInfo(id: 652, isFullScreen: true, desktopNumber: nil, display: "A", isShown: true)
    private var spaces: [SpaceInfo] { [desktop1, claude, chrome] }
    private let arrows = SpaceShortcuts(left: SystemShortcut(keyCode: 123, modifiers: 0x840000),
                                        right: SystemShortcut(keyCode: 124, modifiers: 0x840000), desktops: [:])

    private func win(_ id: WindowNumber, on space: UInt64, minimized: Bool = false) -> DockWindow {
        DockWindow(id: id, pid: 1, bundleID: "a", appName: "A", title: "", bounds: .zero,
                   isOnScreen: false, isMinimized: minimized, spaceIDs: [space])
    }

    func testGoesToTheMostRecentWindowOfThatSpace() {
        let windows = [win(1, on: 652), win(2, on: 681), win(3, on: 681)]
        XCTAssertEqual(SpaceNavigation.move(to: claude, spaces: spaces, windows: windows, shortcuts: arrows), .focus(2))
    }

    func testMinimizedWindowsDoNotCount() {
        let windows = [win(1, on: 3, minimized: true)]
        XCTAssertEqual(SpaceNavigation.move(to: desktop1, spaces: spaces, windows: windows, shortcuts: arrows),
                       .press(SystemShortcut(keyCode: 123, modifiers: 0x840000), times: 2))
    }

    func testEmptyDesktopPrefersItsOwnShortcut() {
        let numbered = SpaceShortcuts(left: arrows.left, right: arrows.right,
                                      desktops: [1: SystemShortcut(keyCode: 18, modifiers: 0x40000)])
        XCTAssertEqual(SpaceNavigation.move(to: desktop1, spaces: spaces, windows: [], shortcuts: numbered),
                       .press(SystemShortcut(keyCode: 18, modifiers: 0x40000), times: 1))
    }

    func testNoWayThereAndAlreadyThere() {
        let none = SpaceShortcuts(left: nil, right: nil, desktops: [:])
        XCTAssertEqual(SpaceNavigation.move(to: desktop1, spaces: spaces, windows: [], shortcuts: none), .none)
        XCTAssertEqual(SpaceNavigation.move(to: chrome, spaces: spaces, windows: [], shortcuts: arrows), .none)
    }

    func testParsesSystemShortcutsWithDefaults() {
        let parsed = SpaceShortcuts.parse([
            "79": ["enabled": NSNumber(value: 1), "value": ["parameters": [65535, 123, 8650752].map(NSNumber.init(value:))]],
            "81": ["enabled": NSNumber(value: 0)],
            "118": ["enabled": NSNumber(value: 1), "value": ["parameters": [65535, 18, 262144].map(NSNumber.init(value:))]],
        ])
        XCTAssertEqual(parsed.left, SystemShortcut(keyCode: 123, modifiers: 8650752))
        XCTAssertNil(parsed.right, "switched off")
        XCTAssertEqual(parsed.desktops, [1: SystemShortcut(keyCode: 18, modifiers: 262144)])
        let defaults = SpaceShortcuts.parse(nil)
        XCTAssertEqual(defaults.right?.keyCode, 124)
        XCTAssertTrue(defaults.desktops.isEmpty)
    }

    func testSpacesInMissionControlOrder() {
        let displays: [[String: Any]] = [[
            "Display Identifier": "A",
            "Current Space": ["ManagedSpaceID": NSNumber(value: 652)],
            "Spaces": [["ManagedSpaceID": NSNumber(value: 3), "type": NSNumber(value: 0)],
                       ["ManagedSpaceID": NSNumber(value: 681), "type": NSNumber(value: 4)],
                       ["ManagedSpaceID": NSNumber(value: 652), "type": NSNumber(value: 4)]],
        ]]
        XCTAssertEqual(SpaceDirectory.spaces(displays: displays, activeSpace: 652), spaces)
    }
}

final class DesktopStartTests: XCTestCase {
    private func space(_ id: UInt64, shown: Bool = false) -> SpaceInfo {
        SpaceInfo(id: id, isFullScreen: false, desktopNumber: Int(id), display: "A", isShown: shown)
    }

    func testFirstPressGoesBackToTheLastDesktop() {
        let spaces = [space(1), space(2, shown: true), space(3)]
        XCTAssertEqual(DesktopStart.selection(spaces: spaces, recent: [2, 3, 1], reverse: false), 2)
    }

    func testWithoutHistoryTheNextOneToTheRight() {
        let spaces = [space(1), space(2), space(3, shown: true)]
        XCTAssertEqual(DesktopStart.selection(spaces: spaces, recent: [], reverse: false), 0, "wraps around")
    }

    func testShiftSelectsTheLeftNeighbour() {
        let spaces = [space(1, shown: true), space(2), space(3)]
        XCTAssertEqual(DesktopStart.selection(spaces: spaces, recent: [1, 3], reverse: true), 2)
    }

    func testOneSpace() {
        XCTAssertEqual(DesktopStart.selection(spaces: [space(1, shown: true)], recent: [], reverse: false), 0)
    }
}

final class WindowLayoutTests: XCTestCase {
    private let laptop = DisplayInfo(id: "L", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    private let monitor = DisplayInfo(id: "M", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
                                      visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1415))

    private func saved(_ frame: CGRect, on display: DisplayInfo?) -> SavedWindow {
        SavedWindow(bundleID: "a", appName: "A", title: "T", frame: frame, display: display?.id,
                    relativeFrame: display.map { WindowLayoutMath.relative(frame, in: $0.visibleFrame) })
    }

    func testSameDisplaysKeepTheExactFrame() {
        let frame = CGRect(x: 1600, y: 100, width: 1200, height: 800)
        XCTAssertEqual(WindowLayoutMath.resolve(saved(frame, on: monitor), displays: [laptop, monitor]), frame)
    }

    func testMissingMonitorMovesItsWindowOntoTheLaptopProportionally() {
        // Right half of the monitor → right half of the laptop.
        let frame = CGRect(x: 1440 + 1280, y: 0, width: 1280, height: 1415)
        let result = WindowLayoutMath.resolve(saved(frame, on: monitor), displays: [laptop])
        XCTAssertEqual(result, CGRect(x: 720, y: 0, width: 720, height: 875))
    }

    func testOldLayoutsWithoutDisplayAreClampedOnScreen() {
        let offScreen = SavedWindow(bundleID: "a", appName: "A", title: "", frame: CGRect(x: 3000, y: 200, width: 800, height: 600))
        let result = WindowLayoutMath.resolve(offScreen, displays: [laptop])
        XCTAssertTrue(laptop.visibleFrame.contains(result))
        XCTAssertEqual(result.size, CGSize(width: 800, height: 600))
    }

    func testDisplaySetKeyIgnoresOrder() {
        XCTAssertEqual(WindowLayoutMath.displaySetKey([laptop, monitor]), WindowLayoutMath.displaySetKey([monitor, laptop]))
        XCTAssertNotEqual(WindowLayoutMath.displaySetKey([laptop]), WindowLayoutMath.displaySetKey([laptop, monitor]))
    }

    func testDisplayForAFrameIsTheOneShowingMostOfIt() {
        XCTAssertEqual(WindowLayoutMath.display(for: CGRect(x: 1300, y: 0, width: 600, height: 400), among: [laptop, monitor])?.id, "M")
        XCTAssertEqual(WindowLayoutMath.display(for: CGRect(x: -900, y: 0, width: 100, height: 100), among: [laptop, monitor])?.id, "L")
    }

    func testRecorderGivesTheLayoutFromBeforeTheChange() {
        var recorder = LayoutRecorder()
        let before = [saved(CGRect(x: 0, y: 0, width: 100, height: 100), on: laptop)]
        let piledUp = [saved(CGRect(x: 10, y: 10, width: 100, height: 100), on: laptop)]
        let t = Date(timeIntervalSince1970: 1000)
        recorder.record(before, at: t)
        recorder.record(piledUp, at: t.addingTimeInterval(9.5))
        XCTAssertEqual(recorder.layout(before: t.addingTimeInterval(8)), before)
    }

    func testUndoHistoryIsBoundedAndLastInFirstOut() {
        var history = LayoutHistory()
        for index in 0..<12 { history.push([saved(CGRect(x: index, y: 0, width: 10, height: 10), on: nil)]) }
        XCTAssertEqual(history.entries.count, 10)
        XCTAssertEqual(history.pop()?.first?.frame.minX, 11)
        XCTAssertNil(LayoutHistory().entries.first)
    }

    func testOldWorkspaceJSONStillLoads() throws {
        let json = #"{"version":1,"profiles":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work","createdAt":0,"windows":[{"bundleID":"a","appName":"A","title":"T","frame":[[0,0],[10,10]]}]}]}"#
        let library = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(library.profiles.first?.windows.first?.display, nil)
        XCTAssertNil(library.profiles.first?.hotKey)
    }

    func testFreeHotKeyIsTheFirstUnusedNumber() {
        let profiles = [WorkspaceProfile(name: "A", windows: [], hotKey: 1), WorkspaceProfile(name: "B", windows: [], hotKey: 3)]
        XCTAssertEqual(WorkspaceProfile.freeHotKey(among: profiles), 2)
    }
}

final class PlacementCycleTests: XCTestCase {
    private let usable = CGRect(x: 0, y: 0, width: 1800, height: 1000)

    func testArrowCyclesHalfThirdTwoThirds() {
        let half = PlacementCycle.frame(for: .left, current: CGRect(x: 300, y: 300, width: 600, height: 400), usable: usable)
        XCTAssertEqual(half, CGRect(x: 0, y: 0, width: 900, height: 1000))
        let third = PlacementCycle.frame(for: .left, current: half, usable: usable)
        XCTAssertEqual(third, CGRect(x: 0, y: 0, width: 600, height: 1000))
        let twoThirds = PlacementCycle.frame(for: .left, current: third, usable: usable)
        XCTAssertEqual(twoThirds, CGRect(x: 0, y: 0, width: 1200, height: 1000))
        XCTAssertEqual(PlacementCycle.frame(for: .left, current: twoThirds, usable: usable), half, "wraps around")
    }

    func testRightAndVerticalSides() {
        XCTAssertEqual(PlacementCycle.frame(for: .right, current: .zero, usable: usable), CGRect(x: 900, y: 0, width: 900, height: 1000))
        XCTAssertEqual(PlacementCycle.frame(for: .up, current: .zero, usable: usable), CGRect(x: 0, y: 500, width: 1800, height: 500))
        XCTAssertEqual(PlacementCycle.frame(for: .down, current: .zero, usable: usable), CGRect(x: 0, y: 0, width: 1800, height: 500))
    }

    func testSlackForAppsThatRoundTheirSize() {
        // A terminal snapped to 894 instead of 900 wide still counts as the half.
        let third = PlacementCycle.frame(for: .left, current: CGRect(x: 0, y: 0, width: 894, height: 996), usable: usable)
        XCTAssertEqual(third.width, 600)
    }

    func testFillAndCenter() {
        XCTAssertEqual(PlacementCycle.frame(for: .fill, current: .zero, usable: usable), usable)
        XCTAssertEqual(PlacementCycle.frame(for: .center, current: CGRect(x: 0, y: 0, width: 800, height: 600), usable: usable),
                       CGRect(x: 500, y: 200, width: 800, height: 600))
    }

    func testMoveToAnotherDisplayKeepsTheProportions() {
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let monitor = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
        let leftHalf = CGRect(x: 0, y: 0, width: 720, height: 875)
        XCTAssertEqual(PlacementCycle.move(leftHalf, from: laptop, to: monitor), CGRect(x: 1440, y: 0, width: 1280, height: 1415))
    }
}

final class WindowRuleTests: XCTestCase {
    func testOnlyNewVisibleWindowsOfRuledAppsArePlaced() {
        let rules = [WindowRule(bundleID: "chrome", appName: "Chrome", placement: .leftHalf)]
        let added = [window(1, "chrome"), window(2, "notes"), window(3, "chrome", minimized: true)]
        let result = WindowRule.placements(for: added, rules: rules)
        XCTAssertEqual(result.map(\.window.id), [1])
        XCTAssertEqual(result.first?.placement, .leftHalf)
    }

    func testRulesRoundTripThroughJSON() throws {
        let rules = [WindowRule(bundleID: "a", appName: "A", placement: .fill)]
        XCTAssertEqual(try JSONDecoder().decode([WindowRule].self, from: JSONEncoder().encode(rules)), rules)
    }
}
