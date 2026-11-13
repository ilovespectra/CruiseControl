import AppKit
import Foundation
import PDFKit

/// Imports document text into a task's Markdown definition. The source file stays where the user chose it;
/// only the extracted text is saved in Cruise's existing per-task definition field.
public enum DoneDefinitionDocument {
    public enum ImportError: LocalizedError, Equatable {
        case unsupportedFileType(String)
        case noReadableText
        case exceedsCharacterLimit(required: Int, maximum: Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFileType(let fileExtension):
                let shown = fileExtension.isEmpty ? "unknown" : ".\(fileExtension)"
                return "\(shown) files aren't supported. Choose a .txt, .md, .rtf, or text-based .pdf document."
            case .noReadableText:
                return "No readable text was found. Scanned-image PDFs aren't supported yet."
            case .exceedsCharacterLimit(let required, let maximum):
                return "This would use \(required) characters, over the \(maximum)-character limit. Shorten the definition or document first."
            }
        }
    }

    public static func readText(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fileExtension = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        let text: String
        switch fileExtension {
        case "txt", "md", "markdown":
            text = String(decoding: data, as: UTF8.self)
        case "rtf":
            text = try NSAttributedString(data: data,
                                          options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil).string
        case "pdf":
            guard let pdf = PDFDocument(data: data) else { throw ImportError.noReadableText }
            text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
        default:
            throw ImportError.unsupportedFileType(fileExtension)
        }

        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ImportError.noReadableText }
        return cleaned
    }

    public static func appending(_ contents: String, filename: String, to definition: String,
                                 maximum: Int = DefinitionOfDone.maxDefinitionLength) throws -> String {
        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.noReadableText }
        let safeName = filename.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        // Quote each source line so the preview keeps the imported document distinct from
        // the user's own criteria, while retaining a lossless, parseable copy for bump delivery.
        let quotedText = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let document = "### Imported document: \(safeName)\n\n\(quotedText)"
        let existing = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = existing.isEmpty ? document : "\(existing)\n\n\(document)"
        guard combined.count <= maximum else {
            throw ImportError.exceedsCharacterLimit(required: combined.count, maximum: maximum)
        }
        return combined
    }

    /// Adds every imported source's extracted text verbatim to the bump that Cruise sends to HeyClicky.
    /// The definition stores imported lines as a Markdown block quote; legacy plain-text sections are read too.
    public static func appendingImportedDocuments(to message: String, from definition: String) -> String {
        let documents = importedDocuments(in: definition)
        guard !documents.isEmpty else { return message }
        let included = documents.map { document in
            "Imported document \(document.filename) (parsed text, verbatim):\n\(document.text)"
        }.joined(separator: "\n\n")
        return "\(message)\n\n\(included)"
    }

    private static func importedDocuments(in definition: String) -> [(filename: String, text: String)] {
        let lines = definition.components(separatedBy: "\n")
        let heading = "### Imported document: "
        var documents: [(filename: String, text: String)] = []
        var index = 0

        while index < lines.count {
            guard lines[index].hasPrefix(heading) else { index += 1; continue }
            let filename = String(lines[index].dropFirst(heading.count)).trimmingCharacters(in: .whitespaces)
            var cursor = index + 1
            while cursor < lines.count && lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 }

            var extracted: [String] = []
            if cursor < lines.count && lines[cursor].hasPrefix(">") {
                // New format: each imported line, including blank lines, is a Markdown quote.
                while cursor < lines.count && lines[cursor].hasPrefix(">") {
                    var line = String(lines[cursor].dropFirst())
                    if line.hasPrefix(" ") { line.removeFirst() }
                    extracted.append(line)
                    cursor += 1
                }
            } else {
                // Backward compatibility for definitions imported before quoted sections were introduced.
                while cursor < lines.count && !lines[cursor].hasPrefix("### ") {
                    extracted.append(lines[cursor])
                    cursor += 1
                }
            }
            let text = extracted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !filename.isEmpty && !text.isEmpty { documents.append((filename, text)) }
            index = max(cursor, index + 1)
        }
        return documents
    }
}
