import Foundation
import SELPHYColorCore

/// A physical colour target the user can own. The patches are in row-major order; four corner
/// patches are clicked on the scan and the others are found by interpolation.
enum ColourTargetModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic24
    case sg140

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic24: tr("ColorChecker Classic (24 patches)")
        case .sg140: tr("ColorChecker SG (140 patches)")
        }
    }

    var columns: Int { self == .classic24 ? 6 : 14 }
    var rows: Int { self == .classic24 ? 4 : 10 }
    var patchCount: Int { columns * rows }

    /// The patches whose centres the user clicks, in this order: top-left, top-right,
    /// bottom-left, bottom-right of the grid.
    var cornerPatches: [String] {
        switch self {
        case .classic24: [tr("dark skin (top left)"), tr("bluish green (top right)"), tr("white (bottom left)"), tr("black (bottom right)")]
        case .sg140: [tr("A1"), tr("N1"), tr("A10"), tr("N10")]
        }
    }

    var orientationHint: String {
        switch self {
        case .classic24: tr("Chart upright: the row of greys at the bottom.")
        case .sg140: tr("Use the patch labels printed on the chart (letters A to N, numbers 1 to 10).")
        }
    }

    static func model(forPatchCount count: Int) -> ColourTargetModel? {
        allCases.first { $0.patchCount == count }
    }
}

struct ReferencePatch: Codable, Equatable, Sendable {
    var name: String
    var l: Double
    var a: Double
    var b: Double

    var lab: [Double] { [l, a, b] }
}

/// Reference CIELab values (D50) of one edition of a target, built in or imported by the user.
struct ReferenceSet: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var model: ColourTargetModel
    var edition: String
    var note: String
    var source: String
    var patches: [ReferencePatch]

    /// The owner's chart (ColorChecker Classic made before November 2014): the default.
    static let defaultID = "classic-before-2014"

    static var `default`: ReferenceSet { builtIn.first { $0.id == defaultID }! }

    static func builtIn(id: String) -> ReferenceSet? { builtIn.first { $0.id == id } }

    var title: String { "\(model.title), \(edition)" }
    var isImported: Bool { id.hasPrefix("imported-") }
}

/// Reads reference values supplied by the user: CSV (a header with L, a, b columns; optional
/// name or patch column; comma, semicolon or tab separated) or CGATS / IT8 text (LAB_L, LAB_A,
/// LAB_B, or XYZ_X, XYZ_Y, XYZ_Z with Y = 100 for white, converted to Lab D50).
enum ReferenceImport {
    enum ImportError: LocalizedError, Equatable {
        case noData
        case missingColumns
        case badValue(Int)
        case wrongCount(Int)

        var errorDescription: String? {
            switch self {
            case .noData: tr("The file contains no measurement rows.")
            case .missingColumns: tr("The file needs L, a, b columns (CSV) or LAB_L, LAB_A, LAB_B / XYZ_X, XYZ_Y, XYZ_Z fields (CGATS).")
            case .badValue(let row): trf("Row %d has a value that is not a number.", row)
            case .wrongCount(let count): trf("Found %d patches: a ColorChecker Classic has 24, a ColorChecker SG 140.", count)
            }
        }
    }

    static func parse(_ text: String, name: String) throws -> ReferenceSet {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let isCGATS = lines.contains { $0.trimmingCharacters(in: .whitespaces).uppercased() == "BEGIN_DATA_FORMAT" }
        let patches = try isCGATS ? parseCGATS(lines) : parseCSV(lines)
        guard !patches.isEmpty else { throw ImportError.noData }
        guard let model = ColourTargetModel.model(forPatchCount: patches.count) else {
            throw ImportError.wrongCount(patches.count)
        }
        return ReferenceSet(
            id: "imported-\(UUID().uuidString)", model: model, edition: trf("imported from %@", name),
            note: tr("Values supplied by the user."), source: name, patches: patches)
    }

    private static func fields(_ line: String) -> [String] {
        let separators: [Character] = line.contains("\t") ? ["\t"] : (line.contains(";") ? [";"] : [","])
        return line.split(separator: separators[0], omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    private static func parseCSV(_ lines: [String]) throws -> [ReferencePatch] {
        let rows = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        guard let header = rows.first else { throw ImportError.noData }
        let names = fields(header).map { $0.lowercased() }
        func column(_ candidates: [String]) -> Int? { names.firstIndex { candidates.contains($0) } }
        guard let li = column(["l", "l*", "lab_l"]), let ai = column(["a", "a*", "lab_a"]),
              let bi = column(["b", "b*", "lab_b"]) else { throw ImportError.missingColumns }
        let ni = column(["name", "sample_name", "patch", "id", "sample_id"])
        var patches: [ReferencePatch] = []
        for (index, row) in rows.dropFirst().enumerated() {
            let values = fields(row)
            guard values.count > max(li, ai, bi) else { throw ImportError.badValue(index + 2) }
            guard let l = number(values[li]), let a = number(values[ai]), let b = number(values[bi]) else {
                throw ImportError.badValue(index + 2)
            }
            let name = ni.flatMap { values.indices.contains($0) ? values[$0] : nil } ?? "\(index + 1)"
            patches.append(ReferencePatch(name: name, l: l, a: a, b: b))
        }
        return patches
    }

    private static func parseCGATS(_ lines: [String]) throws -> [ReferencePatch] {
        var format: [String] = []
        var inFormat = false, inData = false
        var rows: [[String]] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch line.uppercased() {
            case "BEGIN_DATA_FORMAT": inFormat = true; continue
            case "END_DATA_FORMAT": inFormat = false; continue
            case "BEGIN_DATA": inData = true; continue
            case "END_DATA": inData = false; continue
            default: break
            }
            let tokens = cgatsTokens(line)
            if inFormat { format += tokens.map { $0.uppercased() } }
            if inData, !tokens.isEmpty { rows.append(tokens) }
        }
        func column(_ name: String) -> Int? { format.firstIndex(of: name) }
        let nameIndex = column("SAMPLE_NAME") ?? column("SAMPLE_ID")
        var patches: [ReferencePatch] = []
        if let li = column("LAB_L"), let ai = column("LAB_A"), let bi = column("LAB_B") {
            for (index, row) in rows.enumerated() {
                guard row.count > max(li, ai, bi), let l = number(row[li]), let a = number(row[ai]), let b = number(row[bi]) else {
                    throw ImportError.badValue(index + 1)
                }
                patches.append(ReferencePatch(name: nameIndex.map { row[$0] } ?? "\(index + 1)",
                                              l: l, a: a, b: b))
            }
        } else if let xi = column("XYZ_X"), let yi = column("XYZ_Y"), let zi = column("XYZ_Z") {
            for (index, row) in rows.enumerated() {
                guard row.count > max(xi, yi, zi), let x = number(row[xi]), let y = number(row[yi]), let z = number(row[zi]) else {
                    throw ImportError.badValue(index + 1)
                }
                let lab = LabMath.xyzToLab([x / 100, y / 100, z / 100])
                patches.append(ReferencePatch(name: nameIndex.map { row[$0] } ?? "\(index + 1)", l: lab[0], a: lab[1], b: lab[2]))
            }
        } else {
            throw ImportError.missingColumns
        }
        return patches
    }

    /// Splits a CGATS line on blanks, keeping quoted strings ("dark skin") as one token.
    static func cgatsTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                hasToken = true
            } else if !quoted && (character == " " || character == "\t") {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }
}

/// CIELab helpers matching validation/selphy_core.py (D50 = ICC PCS white).
enum LabMath {
    static let d50: [Double] = [0.9642, 1.0, 0.8249]

    static func labToXYZ(_ lab: [Double]) -> [Double] {
        let fy = (lab[0] + 16) / 116
        let fx = fy + lab[1] / 500
        let fz = fy - lab[2] / 200
        let d = 6.0 / 29
        func inv(_ t: Double) -> Double { t > d ? t * t * t : 3 * d * d * (t - 4.0 / 29) }
        return [inv(fx) * d50[0], inv(fy) * d50[1], inv(fz) * d50[2]]
    }

    static func xyzToLab(_ xyz: [Double]) -> [Double] {
        let d = 6.0 / 29
        func f(_ v: Double) -> Double { v > d * d * d ? cbrt(v) : v / (3 * d * d) + 4.0 / 29 }
        let fx = f(xyz[0] / d50[0]), fy = f(xyz[1] / d50[1]), fz = f(xyz[2] / d50[2])
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
    }

    /// Re-expresses Lab relative to the measured paper white (media-relative), as the intended values.
    static func normaliseToPaperWhite(_ lab: [Double], white: [Double]) -> [Double] {
        let xyz = labToXYZ(lab), w = labToXYZ(white)
        return xyzToLab([xyz[0] / w[0] * d50[0], xyz[1] / w[1] * d50[1], xyz[2] / w[2] * d50[2]])
    }

    static func deltaE00(_ a: [Double], _ b: [Double]) -> Double {
        selphy_delta_e2000(a, b)
    }

    static func chroma(_ lab: [Double]) -> Double { (lab[1] * lab[1] + lab[2] * lab[2]).squareRoot() }
}
