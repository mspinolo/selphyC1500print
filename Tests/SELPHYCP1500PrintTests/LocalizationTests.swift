import XCTest
@testable import SELPHYCP1500Print

@MainActor
final class LocalizationTests: XCTestCase {
    override func tearDown() {
        Localizer.shared.language = .english
        super.tearDown()
    }

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SELPHYCP1500Print")
    }

    /// Every text passed to tr/trf/trn in the sources.
    private func keysUsedInSources() throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ItalianStrings.swift" }
        let literal = #""((?:[^"\\]|\\.)*)""#
        let patterns = [#"\btr\("#, #"\btrf\("#, #"\bone: "#, #"\bother: "#].map { try! NSRegularExpression(pattern: $0 + literal) }
        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for regex in patterns {
                for match in regex.matches(in: text, range: range) {
                    keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
                }
            }
        }
        return keys
    }

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\.\d+)?[@dfs]"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }
    }

    func testEveryKeyUsedInTheSourcesHasAnItalianTranslation() throws {
        let keys = try keysUsedInSources()
        XCTAssertGreaterThan(keys.count, 80, "the scan should find the interface texts")
        let missing = keys.filter { ItalianStrings.table[$0] == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, "missing Italian translations: \(missing)")
    }

    func testTranslationTableHasNoDeadOrBrokenEntries() throws {
        let keys = try keysUsedInSources()
        let dead = ItalianStrings.table.keys.filter { !keys.contains($0) }.sorted()
        XCTAssertTrue(dead.isEmpty, "entries not used by the code: \(dead)")
        for (english, italian) in ItalianStrings.table {
            XCTAssertEqual(placeholders(english), placeholders(italian), "placeholders differ: \(english)")
            XCTAssertFalse(italian.isEmpty)
        }
    }

    func testEnglishIsTheDefaultAndItalianCanBeSelected() throws {
        let suite = "selphy-l10n-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(tr("Cancel"), "Cancel")
        XCTAssertEqual(RenderingIntent.perceptual.title, "Perceptual")

        settings.language = .italian
        XCTAssertEqual(tr("Cancel"), "Annulla")
        XCTAssertEqual(RenderingIntent.perceptual.title, "Percettivo")
        XCTAssertEqual(OutputFormat.png.title, "PNG (senza perdita)")

        // The choice survives a restart.
        Localizer.shared.language = .english
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.language, .italian)
        XCTAssertEqual(Localizer.shared.language, .italian)
    }

    func testFormattingPluralsAndFallback() {
        Localizer.shared.language = .english
        XCTAssertEqual(trn(1, one: "1 photo selected", other: "%d photos selected"), "1 photo selected")
        XCTAssertEqual(trn(3, one: "1 photo selected", other: "%d photos selected"), "3 photos selected")
        XCTAssertEqual(trf("Predicted deviation from the original: mean %.1f, 95th percentile %.1f (ΔE00).", 1.24, 3.5),
                       "Predicted deviation from the original: mean 1.2, 95th percentile 3.5 (ΔE00).")

        Localizer.shared.language = .italian
        XCTAssertEqual(trn(3, one: "1 photo selected", other: "%d photos selected"), "3 fotografie selezionate")
        XCTAssertEqual(trn(1, one: "1 photo selected", other: "%d photos selected"), "1 fotografia selezionata")
        XCTAssertTrue(trf("Predicted deviation from the original: mean %.1f, 95th percentile %.1f (ΔE00).", 1.3, 3.5).contains("1,3"),
                      "Italian uses the decimal comma")
        XCTAssertEqual(tr("Text that is not translated"), "Text that is not translated", "unknown keys fall back to English")
    }

    func testErrorMessagesFollowTheLanguage() {
        Localizer.shared.language = .english
        let english = ColorCorrectionService.CorrectionError.cancelled.errorDescription
        Localizer.shared.language = .italian
        let italian = ColorCorrectionService.CorrectionError.cancelled.errorDescription
        XCTAssertEqual(english, "Conversion cancelled.")
        XCTAssertEqual(italian, "Conversione annullata.")
    }
}
