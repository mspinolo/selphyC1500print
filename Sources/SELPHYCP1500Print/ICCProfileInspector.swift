import Foundation

struct ICCProfileReport {
    let fileSize: Int
    let version: String
    let profileClass: String
    let colorSpace: String
    let connectionSpace: String
    let defaultRenderingIntent: UInt32
    let tags: Set<String>

    var availableIntents: [RenderingIntent] {
        let pairs: [(RenderingIntent, String, String)] = [
            (.perceptual, "A2B0", "B2A0"),
            (.relativeColorimetric, "A2B1", "B2A1"),
            (.saturation, "A2B2", "B2A2")
        ]
        return pairs.compactMap { intent, forward, reverse in
            tags.contains(forward) && tags.contains(reverse) ? intent : nil
        }
    }

    var isExpectedPrinterProfile: Bool {
        profileClass == "prtr" && colorSpace == "RGB " && connectionSpace == "Lab "
    }

    var summary: String {
        guard isExpectedPrinterProfile else {
            return "Profilo caricato, ma classe/spazio colore non corrispondono a un profilo stampante RGB con PCS Lab."
        }
        return "Profilo stampante RGB / Lab valido. Tabelle disponibili: " +
            availableIntents.map(\\.title).joined(separator: ", ")
    }
}

enum ICCProfileInspector {
    enum InspectionError: LocalizedError {
        case tooShort
        case invalidDeclaredSize
        case missingSignature
        case invalidTagTable

        var errorDescription: String? {
            switch self {
            case .tooShort: "Il file è troppo corto per contenere un profilo ICC."
            case .invalidDeclaredSize: "La dimensione dichiarata nell'intestazione ICC non coincide con quella del file."
            case .missingSignature: "Firma ICC 'acsp' non trovata."
            case .invalidTagTable: "La tabella dei tag ICC è incompleta o contiene offset/dimensioni non validi."
            }
        }
    }

    private static let headerAndCountSize = 132
    private static let tagEntrySize = 12

    static func inspect(url: URL) throws -> ICCProfileReport {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= headerAndCountSize else { throw InspectionError.tooShort }

        let declaredSize = Int(readUInt32(data, at: 0))
        guard declaredSize == data.count else { throw InspectionError.invalidDeclaredSize }
        guard readSignature(data, at: 36) == "acsp" else { throw InspectionError.missingSignature }

        let tagCount = Int(readUInt32(data, at: 128))
        let availableTableBytes = data.count - headerAndCountSize
        guard tagCount <= availableTableBytes / tagEntrySize else {
            throw InspectionError.invalidTagTable
        }

        let tagTableEnd = headerAndCountSize + tagCount * tagEntrySize
        var tags = Set<String>()

        for index in 0..<tagCount {
            let entry = headerAndCountSize + index * tagEntrySize
            let signature = readSignature(data, at: entry)
            let offset = Int(readUInt32(data, at: entry + 4))
            let size = Int(readUInt32(data, at: entry + 8))

            // ICC tag data must be non-empty, 4-byte aligned, and located
            // after the complete tag table. Subtraction-based bounds checking
            // avoids overflow in offset + size.
            guard size > 0,
                  offset >= tagTableEnd,
                  offset.isMultiple(of: 4),
                  offset <= data.count,
                  size <= data.count - offset else {
                throw InspectionError.invalidTagTable
            }
            tags.insert(signature)
        }

        let versionMajor = data[8]
        let versionMinor = data[9] >> 4
        return ICCProfileReport(
            fileSize: data.count,
            version: "\\(versionMajor).\\(versionMinor)",
            profileClass: readSignature(data, at: 12),
            colorSpace: readSignature(data, at: 16),
            connectionSpace: readSignature(data, at: 20),
            defaultRenderingIntent: readUInt32(data, at: 64),
            tags: tags
        )
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) |
        (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) |
        UInt32(data[offset + 3])
    }

    private static func readSignature(_ data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }
}
