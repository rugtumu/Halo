import XCTest
@testable import Halo

final class WheelGeometryTests: XCTestCase {
    private let wheel = WheelGeometry(count: 8)

    // Dropping back on the hub is how users cancel, so it must never trigger an action.
    func testHubDropCancels() {
        XCTAssertNil(wheel.index(at: .zero))
        XCTAssertNil(wheel.index(at: CGPoint(x: 0, y: -(wheel.inner - 1))))
    }

    // The first item is drawn at 12 o'clock and items run clockwise; hit-testing must agree with the drawing.
    func testFirstItemAtTopAndClockwiseOrder() {
        XCTAssertEqual(wheel.index(at: CGPoint(x: 0, y: -120)), 0)
        XCTAssertEqual(wheel.index(at: CGPoint(x: 120, y: 0)), 2)
        XCTAssertEqual(wheel.index(at: CGPoint(x: 0, y: 120)), 4)
        XCTAssertEqual(wheel.index(at: CGPoint(x: -120, y: 0)), 6)
    }

    // A fast flick that lands just past the rim still counts; a drop far outside does not.
    func testOuterTolerance() {
        XCTAssertEqual(wheel.index(at: CGPoint(x: 0, y: -(wheel.outer + 8))), 0)
        XCTAssertNil(wheel.index(at: CGPoint(x: 0, y: -(wheel.outer + 40))))
    }
}

final class CatalogTests: XCTestCase {
    // Offering "PNG → PNG" would be a no-op that looks like a bug.
    func testNoSelfConversion() {
        for matrix in Catalog.matrices {
            for row in matrix.rows {
                XCTAssertFalse(row.targets.contains(row.source), "\(row.source) converts to itself")
            }
        }
    }

    // The compatibility table is drawn from the columns; a target outside them would be invisible there.
    func testTargetsAreListedColumns() {
        for matrix in Catalog.matrices {
            for row in matrix.rows {
                XCTAssertTrue(Set(row.targets).isSubset(of: matrix.columns), "\(row.source) has unlisted targets")
            }
        }
    }

    // Finder files named .JPEG or .tif must get the same wheel as .jpg/.tiff.
    func testExtensionAliases() {
        XCTAssertEqual(Catalog.row(for: URL(fileURLWithPath: "/a/B.JPEG"))?.source, "jpg")
        XCTAssertEqual(Catalog.row(for: URL(fileURLWithPath: "/a/b.tif"))?.source, "tiff")
        XCTAssertEqual(Catalog.row(for: URL(fileURLWithPath: "/a/b.tar.gz"))?.source, "gzip")
    }

    // A multi-file drop only offers formats every file can reach; mixing categories offers nothing.
    func testMixedSelections() {
        let images = Catalog.targets(for: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.jpg")])
        XCTAssertEqual(images?.category, .image)
        XCTAssertTrue(images?.targets.contains("webp") == true)
        XCTAssertFalse(images?.targets.contains("png") == true)
        XCTAssertFalse(images?.targets.contains("jpg") == true)
        XCTAssertNil(Catalog.targets(for: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.mp3")]))
    }
}

final class OutputTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try Output.tempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // Results must never overwrite the original or an earlier result.
    func testNeverOverwrites() throws {
        let source = folder.appendingPathComponent("photo.png")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("photo.jpg").path, contents: Data())
        XCTAssertEqual(Output.url(for: source, ext: "jpg", folder: folder).lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(Output.url(for: source, ext: "png", folder: folder).lastPathComponent, "photo.png")
    }

    // "a.tar.gz" → ZIP should be "a.zip", not "a.tar.zip".
    func testTarballBaseName() {
        let source = folder.appendingPathComponent("a.tar.gz")
        XCTAssertEqual(Output.url(for: source, ext: "zip", folder: folder).lastPathComponent, "a.zip")
    }
}

final class SubtitleTests: XCTestCase {
    private let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\n<i>World</i>\n"

    // Players reject VTT without the header or with comma millisecond separators.
    func testSRTToVTTFormat() {
        let vtt = SubtitleEngine.srtToVTT(srt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:02.500"))
    }

    // Converting back and forth must not lose timing or text.
    func testRoundTrip() {
        XCTAssertEqual(SubtitleEngine.vttToSRT(SubtitleEngine.srtToVTT(srt)), srt)
    }

    // VTT allows mm:ss stamps and cue settings; SRT requires hh:mm:ss,mmm and nothing else.
    func testShortVTTStampsAreExpanded() {
        let vtt = "WEBVTT\n\n00:05.000 --> 00:06.000 align:start\nHi\n"
        XCTAssertEqual(SubtitleEngine.vttToSRT(vtt), "1\n00:00:05,000 --> 00:00:06,000\nHi\n")
    }

    // Transcripts should contain only spoken text, without markup.
    func testPlainTextStripsTags() {
        XCTAssertEqual(SubtitleEngine.plainText(srt), "Hello\nWorld\n")
    }
}

/// 100×100 image: top half red, bottom half blue (as seen on screen).
private func splitImage() -> CGImage {
    let ctx = ImageEngine.makeContext(width: 100, height: 100)!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 50))   // CG is bottom-left origin
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
    return ctx.makeImage()!
}

/// RGB of the pixel at (x, y) measured from the top-left, as the user sees it.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let ctx = ImageEngine.makeContext(width: image.width, height: image.height)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let offset = y * ctx.bytesPerRow + x * 4
    return (data[offset], data[offset + 1], data[offset + 2])
}

final class ImageRenderTests: XCTestCase {
    // Editors use top-left normalized rects; a flipped axis would crop the wrong half of the photo.
    func testCropKeepsTheRegionTheUserSelected() throws {
        let top = try XCTUnwrap(ImageRender.crop(splitImage(), to: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        XCTAssertEqual(top.height, 50)
        XCTAssertEqual(pixel(top, 50, 25).r, 255)
        XCTAssertEqual(pixel(top, 50, 25).b, 0)
    }

    // Redaction must cover exactly the marked area — and nothing must leak through it.
    func testBlackBoxRedactsOnlyTheMarkedArea() throws {
        let out = try XCTUnwrap(ImageRender.redact(splitImage(), regions: [CGRect(x: 0, y: 0, width: 1, height: 0.5)], style: .black))
        let hidden = pixel(out, 50, 25), untouched = pixel(out, 50, 75)
        XCTAssertEqual([hidden.r, hidden.g, hidden.b], [0, 0, 0])
        XCTAssertEqual(untouched.b, 255)
    }

    // Rotating clockwise must move the top (red) half to the right side.
    func testRotateClockwise() {
        let rotated = ImageRender.rotate(splitImage(), clockwise: true)
        XCTAssertEqual(pixel(rotated, 90, 50).r, 255)
        XCTAssertEqual(pixel(rotated, 10, 50).b, 255)
    }

    // Padding is relative to the long edge, and a forced aspect only ever grows the canvas.
    func testBackgroundCanvasSize() {
        XCTAssertEqual(ImageRender.canvasSize(imageWidth: 200, imageHeight: 100, padding: 0.1, aspect: nil),
                       CGSize(width: 240, height: 140))
        XCTAssertEqual(ImageRender.canvasSize(imageWidth: 200, imageHeight: 100, padding: 0.1, aspect: 1),
                       CGSize(width: 240, height: 240))
    }
}

final class CropMathTests: XCTestCase {
    // Moving the crop box must never push it outside the image.
    func testMoveStaysInsideImage() {
        let r = CropMath.update(CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), handle: .move, dx: 0.5, dy: -0.9, ratio: nil)
        XCTAssertEqual(r, CGRect(x: 0.6, y: 0, width: 0.4, height: 0.4))
    }

    // With an aspect locked, resizing keeps the ratio and the opposite corner stays put.
    func testLockedAspectKeepsRatioAndAnchor() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let r = CropMath.update(start, handle: .bottomRight, dx: 0.2, dy: 0, ratio: 1)
        XCTAssertEqual(r.width, r.height, accuracy: 1e-9)
        XCTAssertEqual(r.origin, start.origin)
    }

    // A handle dragged past the opposite edge can't collapse or invert the box.
    func testMinimumSize() {
        let r = CropMath.update(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4), handle: .topLeft, dx: 0.9, dy: 0.9, ratio: nil)
        XCTAssertGreaterThanOrEqual(r.width, CropMath.minSide - 1e-9)
        XCTAssertGreaterThanOrEqual(r.height, CropMath.minSide - 1e-9)
    }
}

final class MediaEditTests: XCTestCase {
    // Overlapping bleeps would sum to 2 in ffmpeg's enable expression and play the tone twice as loud.
    func testOverlappingBleepsMerge() {
        XCTAssertEqual(MediaEdit.merge([3...4, 1...2, 1.5...2.5]), [1...2.5, 3...4])
    }

    // Mono output must average both sides, otherwise downmixing clips loud stereo audio.
    func testMonoPanAverages() {
        XCTAssertEqual(MediaEdit.panFilter(mono: true, left: 1, right: 1),
                       "aformat=channel_layouts=stereo,pan=mono|c0=0.500*c0+0.500*c1")
    }

    // Auto-trim keeps everything audible and drops only the quiet lead-in and tail.
    func testSilentBounds() {
        let peaks: [Float] = [0, 0.01, 0.5, 1, 0.4, 0.02, 0, 0, 0, 0]
        XCTAssertEqual(MediaEdit.silentBounds(peaks), 0.2...0.5)
        XCTAssertEqual(MediaEdit.silentBounds([0, 0]), 0...1)
    }
}

/// Runs the real export arguments through ffmpeg, because a filter string that looks right can still be rejected.
final class MediaExportIntegrationTests: XCTestCase {
    private var folder: URL!
    private var tone: URL!

    override func setUp() async throws {
        guard let ffmpeg = Binaries.ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        folder = try Output.tempDirectory()
        tone = folder.appendingPathComponent("tone.m4a")
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                                     "sine=frequency=440:duration=3", "-ac", "2", "-c:a", "aac", tone.path])
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func duration(_ url: URL) async throws -> Double {
        try await AudioPreview.load(url).duration
    }

    func testTrimProducesSelectedLength() async throws {
        let out = try await MediaEdit.export(tone, suffix: "trimmed", ["-ss", "0.500", "-t", "1.000"] + MediaEngine.codec(for: "m4a"))
        let length = try await duration(out)
        XCTAssertEqual(length, 1.0, accuracy: 0.1)
    }

    func testBleepFilterIsAcceptedAndKeepsLength() async throws {
        let out = try await MediaEdit.export(tone, suffix: "bleeped",
                                             ["-filter_complex", MediaEdit.bleepFilter([0.5...1.0, 0.8...1.5]),
                                              "-map", "0:v?", "-map", "[out]"] + MediaEdit.audioCodec(for: tone))
        let length = try await duration(out)
        XCTAssertEqual(length, 3.0, accuracy: 0.15)
    }

    func testChannelFilterIsAccepted() async throws {
        let out = try await MediaEdit.export(tone, suffix: "mono",
                                             ["-af", MediaEdit.panFilter(mono: true, left: 1, right: 0.5)] + MediaEdit.audioCodec(for: tone))
        XCTAssertGreaterThan(Output.size(out), 0)
    }
}

final class WheelOrderTests: XCTestCase {
    // The user's arrangement wins, and items they never placed (e.g. new in an update) still appear, at the end.
    func testSavedOrderFirstNewItemsAppended() {
        XCTAssertEqual(WheelOrder.ordered(["jpg", "png", "webp", "heic"], saved: ["webp", "jpg"]),
                       ["webp", "jpg", "png", "heic"])
    }

    // A saved order may mention formats this file can't reach; they must not appear on the wheel.
    func testUnavailableSavedItemsAreIgnored() {
        XCTAssertEqual(WheelOrder.ordered(["png", "jpg"], saved: ["avif", "jpg"]), ["jpg", "png"])
    }

    // Order is stored per wheel and per file kind, so reordering image tools never affects audio tools.
    func testKeysAreScoped() {
        XCTAssertNotEqual(WheelOrder.key(.tools, .image), WheelOrder.key(.tools, .audio))
        XCTAssertEqual(WheelOrder.key(.actions, nil), "order.actions")
    }
}
