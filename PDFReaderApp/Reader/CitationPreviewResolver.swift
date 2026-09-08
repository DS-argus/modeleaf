import Foundation
import PDFKit
import PDFReaderCore

struct CitationMarker: Equatable {
    let sourcePageIndex: Int
    let sourceBounds: CGRect
    let marker: Int
    let destination: ReaderLinkTarget
}


enum CitationPreviewUnresolvedReason: Equatable {
    case missingTarget
    case invalidDestination
    case referenceUnavailable

    var message: String {
        switch self {
        case .missingTarget: return "Citation target is unavailable."
        case .invalidDestination: return "Citation target coordinates could not be verified."
        case .referenceUnavailable: return "Reference text could not be verified."
        }
    }
}

enum CitationPreviewItemState: Equatable {
    case resolved
    case unresolved(reason: CitationPreviewUnresolvedReason)

    var isResolved: Bool {
        if case .resolved = self { return true }
        return false
    }

    var isUnresolved: Bool { !isResolved }
    var unresolvedReason: CitationPreviewUnresolvedReason? {
        guard case let .unresolved(reason) = self else { return nil }
        return reason
    }
}

struct CitationPreviewItem: Equatable {
    let label: String
    let destination: ReaderLinkTarget?
    let referenceText: String
    let state: CitationPreviewItemState

    init(
        label: String,
        destinationPageIndex: Int,
        destinationPoint: CGPoint,
        referenceText: String,
        state: CitationPreviewItemState = .resolved
    ) {
        self.label = label
        self.destination = .goTo(pageIndex: destinationPageIndex, point: destinationPoint)
        self.referenceText = referenceText
        self.state = state
    }

    init(
        label: String,
        destination: ReaderLinkTarget?,
        referenceText: String,
        state: CitationPreviewItemState = .resolved
    ) {
        self.label = label
        self.destination = destination
        self.referenceText = referenceText
        self.state = state
    }

    var destinationPageIndex: Int? {
        guard case let .goTo(pageIndex, _) = destination else { return nil }
        return pageIndex
    }

    var destinationPoint: CGPoint? {
        guard case let .goTo(_, point) = destination else { return nil }
        return point
    }

    var isResolved: Bool { state.isResolved }
    var isUnresolved: Bool { state.isUnresolved }
    var unresolvedReason: CitationPreviewUnresolvedReason? { state.unresolvedReason }
}

struct CitationPreviewGroup: Equatable {
    let items: [CitationPreviewItem]
    let selectedIndex: Int
    var sourceContext: String? = nil
}

enum LinkHintResolution: Equatable {
    case activate(ReaderLinkTarget)
    case preview(CitationPreviewGroup)
}

struct AuthorYearCitationKey: Equatable {
    let authors: String
    let year: Int
    let yearSuffix: String

    var label: String { "\(authors) \(year)\(yearSuffix)" }
}

struct CitationTextLine: Equatable {
    let text: String
    let bounds: CGRect
}

enum AuthorYearCitationClassifier {
    private static let yearPattern = try! NSRegularExpression(
        pattern: #"\b((?:19|20)[0-9]{2})([a-z]?)\b"#,
        options: [.caseInsensitive]
    )

    static func isYearFragment(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = yearPattern.firstMatch(in: normalized, range: range) else { return false }
        return match.range == range
    }
    static func key(from fragments: [String]) -> AuthorYearCitationKey? {
        let text = CitationPreviewClassifier.cleanedBody(joinFragments(fragments))
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = yearPattern.matches(in: text, range: range)
        guard matches.count == 1,
              let yearRange = Range(matches[0].range(at: 1), in: text),
              let year = Int(text[yearRange])
        else { return nil }
        let suffix = Range(matches[0].range(at: 2), in: text).map { String(text[$0]).lowercased() } ?? ""
        var authors = text
        if let completeYearRange = Range(matches[0].range, in: text) {
            authors.removeSubrange(completeYearRange)
        }
        authors = normalizedAuthors(authors)
        guard authors.rangeOfCharacter(from: .letters) != nil,
              !authors.lowercased().hasPrefix("et al")
        else { return nil }
        return AuthorYearCitationKey(
            authors: authors,
            year: year,
            yearSuffix: suffix
        )
    }

    static func validates(_ key: AuthorYearCitationKey, referenceText: String) -> Bool {
        let foldedReference = folded(referenceText)
        let yearToken = "\(key.year)\(key.yearSuffix)"
        let yearPattern = try! NSRegularExpression(
            pattern: #"(?<![0-9A-Za-z])"# + NSRegularExpression.escapedPattern(for: yearToken) + #"(?![0-9A-Za-z])"#
        )
        let range = NSRange(foldedReference.startIndex..<foldedReference.endIndex, in: foldedReference)
        guard yearPattern.firstMatch(in: foldedReference, range: range) != nil else { return false }

        let authorTokens = key.authors
            .split(whereSeparator: { $0.isWhitespace || $0 == "&" || $0 == "," })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { token in
                let folded = self.folded(token)
                return token.rangeOfCharacter(from: .letters) != nil
                    && !["et", "al", "and"].contains(folded)
            }
        guard let primaryAuthor = authorTokens.first else { return false }
        let authorBoundary = try! NSRegularExpression(pattern: #",|(?<!\b\p{Lu})\.(?:\s|$)"#)
        let rawRange = NSRange(referenceText.startIndex..<referenceText.endIndex, in: referenceText)
        let boundary = authorBoundary.firstMatch(in: referenceText, range: rawRange)?.range.location ?? rawRange.length
        let rawAuthorPrefix = String((referenceText as NSString).substring(to: boundary))
            .replacingOccurrences(of: #"^\s*(?:\[[^\]]+\]|[0-9]{1,4}\.)\s*"#, with: "", options: .regularExpression)
        let particles = Set(["&", "and", "et", "al", "de", "del", "di", "da", "du", "la", "le", "van", "von", "der", "den"])
        let nameTokens = rawAuthorPrefix.replacingOccurrences(of: #"([´ˇ`])\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[\p{L}])-\s+(?=\p{Ll})"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
        guard nameTokens.allSatisfy({ token in
            token.contains(where: \.isUppercase) || particles.contains(token.lowercased())
        }) else { return false }
        let authorPrefix = folded(rawAuthorPrefix)
        let primaryPattern = #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: folded(primaryAuthor)) + #"(?![\p{L}])"#
        guard authorPrefix.range(of: primaryPattern, options: .regularExpression) != nil else { return false }
        return authorTokens.allSatisfy { surname in
            let surnamePattern = try! NSRegularExpression(
                pattern: #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: folded(surname)) + #"(?![\p{L}])"#,
                options: [.caseInsensitive]
            )
            return surnamePattern.firstMatch(in: foldedReference, range: range) != nil
        }
    }

    private static func joinFragments(_ fragments: [String]) -> String {
        var result = ""
        for fragment in fragments {
            let value = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if result.last == "-", value.first?.isLowercase == true {
                result.removeLast()
                result += value
            } else {
                if !result.isEmpty { result += " " }
                result += value
            }
        }
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func normalizedAuthors(_ authors: String) -> String {
        authors
            .replacingOccurrences(of: #"[’']s\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "(),;[]")))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CitationPreviewClassifier {
    private static let exactMarker = try! NSRegularExpression(pattern: #"^\s*(?:([0-9]{1,4})|\[\s*([0-9]{1,4})\s*\]|\(\s*([0-9]{1,4})\s*\))\s*$"#)
    static let groupPattern = #"(?:\[[^\[\]()]{1,2048}\]|\([^()\[\]]{1,2048}\))"#
    private static let bracketedGroup = try! NSRegularExpression(pattern: groupPattern)

    static func marker(in exactSourceText: String) -> Int? {
        let range = NSRange(exactSourceText.startIndex..<exactSourceText.endIndex, in: exactSourceText)
        guard let match = exactMarker.firstMatch(in: exactSourceText, range: range),
              let capture = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound }),
              let markerRange = Range(match.range(at: capture), in: exactSourceText)
        else { return nil }
        return Int(exactSourceText[markerRange])
    }

    static func cleanedBody(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "[]() ").union(.whitespacesAndNewlines))
            .replacingOccurrences(of: #"(?i)^(?:e\.g\.,?|see(?: also)?|cf\.)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i),?\s*(?:pp?\.|pages?|Chapter|Section|Prop\.?)\s*[0-9]+(?:[.–−-][0-9]+)*"#, with: "", options: .regularExpression)
    }

    static func sourceContext(in text: String) -> String? {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]() ").union(.whitespacesAndNewlines))
        guard cleanedBody(text) != body else { return nil }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(Chapter|Section|Prop\.?|pp?\.)(?=[0-9])"#, with: "$1 ", options: .regularExpression)
    }
    static func expandedMarkers(in group: String) -> [Int]? {
        let body = cleanedBody(group)
        var result: [Int] = []
        for component in body.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            let bounds = component.components(separatedBy: CharacterSet(charactersIn: "-–−"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let first = bounds.first.flatMap(Int.init), first > 0, bounds.count <= 2 else { return nil }
            let last = bounds.count == 2 ? Int(bounds[1]) : first
            guard let last, last >= first, last <= 9999, result.count + last - first + 1 <= 256 else { return nil }
            result.append(contentsOf: first...last)
        }
        return result.isEmpty ? nil : result
    }
    static func bracketedGroups(in sourceContext: String) -> [[Int]] {
        let range = NSRange(sourceContext.startIndex..<sourceContext.endIndex, in: sourceContext)
        return bracketedGroup.matches(in: sourceContext, range: range).compactMap { match in
            guard let groupRange = Range(match.range, in: sourceContext) else { return nil }
            let group = String(sourceContext[groupRange])
            return expandedMarkers(in: group)
        }
    }

}

enum CitationReferenceExtractor {
    static let maximumLines = 8
    static let maximumCharacters = 700
    static let maximumLineGap: CGFloat = 18

    static func extract(marker: Int, from lines: [CitationTextLine]) -> String? {
        let ordered = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if abs($0.bounds.maxY - $1.bounds.maxY) > 1 { return $0.bounds.maxY > $1.bounds.maxY }
                return $0.bounds.minX < $1.bounds.minX
            }
        let markerPattern = try! NSRegularExpression(
            pattern: #"^\s*(?:\[\s*\#(marker)\s*\](?:\s|$)|\#(marker)\.[ \t]+\S)"#
        )
        let nextMarkerPattern = try! NSRegularExpression(
            pattern: #"^\s*(?:\[\s*[0-9]{1,4}\s*\](?:\s|$)|[0-9]{1,4}\.[ \t]+\S)"#
        )
        guard let start = ordered.firstIndex(where: { line in
            let range = NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)
            return markerPattern.firstMatch(in: line.text, range: range) != nil
        }) else { return nil }

        var accepted: [String] = []
        var previousBounds: CGRect?
        for line in ordered[start...] {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let wrappedYear = !(1900...2099).contains(marker)
                && text.range(of: #"^(?:19|20)[0-9]{2}\.[ \t]+\S"#, options: .regularExpression) != nil
            if wrappedYear && line.bounds.minX <= ordered[start].bounds.minX + 4 { return nil }
            if !accepted.isEmpty, !wrappedYear, nextMarkerPattern.firstMatch(in: text, range: range) != nil { break }
            if let previousBounds, previousBounds.minY - line.bounds.maxY > maximumLineGap { break }
            if accepted.count == maximumLines { return nil }
            let candidate = (accepted + [text]).joined(separator: " ")
            if candidate.count > maximumCharacters { return nil }
            accepted.append(text)
            previousBounds = line.bounds
        }
        let result = accepted.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

enum CitationReferencePageLayout: Equatable {
    case singleColumn
    case twoColumns(splitX: CGFloat)
}

struct CitationReferenceEntryCandidate: Equatable {
    let columnIndex: Int
    let lines: [CitationTextLine]
    let rawText: String
}

enum CitationReferenceEntryExtractor {
    private static let baselineTolerance: CGFloat = 2
    private static let startIndentTolerance: CGFloat = 4
    private static let destinationTolerance: CGFloat = 36
    private static let destinationSentinelThreshold = CGFloat(Float.greatestFiniteMagnitude) / 2

    static func isUsableDestinationPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite
            && point.y.isFinite
            && abs(point.x) < destinationSentinelThreshold
            && abs(point.y) < destinationSentinelThreshold
    }
    static func isUsableDestinationPoint(_ point: CGPoint, on page: PDFPage) -> Bool {
        isUsableDestinationPoint(point) && page.bounds(for: .mediaBox).union(page.bounds(for: .cropBox))
            .insetBy(dx: -1, dy: -1).contains(point)
    }

    static func layout(of lines: [CitationTextLine], pageBounds: CGRect) -> CitationReferencePageLayout {
        let midpoint = pageBounds.midX
        let usable = lines.filter { $0.bounds.width >= 20 && $0.bounds.height <= 24 }
        let left = usable.filter { $0.bounds.midX < midpoint && $0.bounds.maxX <= midpoint + 4 }
        let right = usable.filter { $0.bounds.midX >= midpoint && $0.bounds.minX >= midpoint - 4 }
        guard left.count >= 2, right.count >= 2 else { return .singleColumn }
        let pairedBaselines = left.reduce(into: 0) { count, lhs in
            if right.contains(where: { $0.bounds.maxY >= lhs.bounds.minY && $0.bounds.minY <= lhs.bounds.maxY }) {
                count += 1
            }
        }
        guard pairedBaselines >= 2 else { return .singleColumn }
        return .twoColumns(splitX: midpoint)
    }

    static func numericEntryLocations(on page: PDFPage) -> [(number: Int, point: CGPoint, bounds: CGRect)] {
        let pattern = try! NSRegularExpression(pattern: #"^\s*(?:\[\s*([0-9]{1,4})\s*\]|([0-9]{1,4})\.)[ \t]+\S"#)
        return columnLines(pageLines(on: page), pageBounds: page.bounds(for: .cropBox)).flatMap { column in
            mergeFragmentsOnBaselines(column).compactMap { line in
                let range = NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)
                guard let match = pattern.firstMatch(in: line.text, range: range),
                      let label = Range(match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1), in: line.text),
                      let number = Int(line.text[label])
                else { return nil }
                return (number: number, point: CGPoint(x: line.bounds.minX, y: line.bounds.maxY), bounds: line.bounds)
            }
        }
    }
    static func numericEntry(marker: Int, destinationPoint: CGPoint, on page: PDFPage) -> String? {
        guard isUsableDestinationPoint(destinationPoint, on: page) else { return nil }
        let pageTextLines = pageLines(on: page)
        let columns = columnLines(pageTextLines, pageBounds: page.bounds(for: .cropBox))
        let pattern = try! NSRegularExpression(pattern: #"^\s*(?:\[\s*\#(marker)\s*\](?:\s|$)|\#(marker)\.[ \t]+\S)"#)
        let matches = columns.compactMap { column -> (text: String, distance: CGFloat)? in
            let lines = mergeFragmentsOnBaselines(column)
            let starts = lines.indices.filter { index in
                pattern.firstMatch(in: lines[index].text, range: NSRange(lines[index].text.startIndex..<lines[index].text.endIndex, in: lines[index].text)) != nil
            }.map { index in
                (index: index, distance: max(lines[index].bounds.minY - destinationPoint.y, destinationPoint.y - lines[index].bounds.maxY, 0))
            }.sorted { $0.distance < $1.distance }
            guard let start = starts.first, start.distance <= destinationTolerance else { return nil }
            if starts.count > 1, abs(starts[1].distance - start.distance) < 1 { return nil }
            if pageTextLines.contains(where: { line in
                abs(line.bounds.minX - lines[start.index].bounds.minX) <= startIndentTolerance
                    && max(line.bounds.minY - destinationPoint.y, destinationPoint.y - line.bounds.maxY, 0) + 1 < start.distance
                    && pattern.firstMatch(in: line.text, range: NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)) != nil
            }) { return nil }
            let nearby = lines[start.index...].filter { $0.bounds.maxY >= destinationPoint.y - 220 }
            guard let text = CitationReferenceExtractor.extract(marker: marker, from: nearby) else { return nil }
            return (text: text, distance: abs(lines[start.index].bounds.minX - destinationPoint.x))
        }.sorted { $0.distance < $1.distance }
        guard let first = matches.first else { return nil }
        if matches.count > 1, abs(matches[1].distance - first.distance) < 4 { return nil }
        return first.text
    }

    static func entry(destinationPoint: CGPoint, on page: PDFPage) -> CitationReferenceEntryCandidate? {
        guard isUsableDestinationPoint(destinationPoint, on: page) else { return nil }
        let matches = candidates(destinationPoint: destinationPoint, on: page)
            .map { candidate in
                let origin = candidate.lines.map { $0.bounds.minX }.min() ?? .greatestFiniteMagnitude
                return (candidate: candidate, distance: abs(origin - destinationPoint.x))
            }
            .sorted { $0.distance < $1.distance }
        guard let first = matches.first else { return nil }
        if matches.count > 1, abs(matches[1].distance - first.distance) < 4 { return nil }
        return first.candidate
    }
    private static func isReferenceStart(_ text: String) -> Bool {
        guard text.range(of: #"^(?:In|A|An|The)\s"#, options: .regularExpression) == nil else { return false }
        return text.range(of: #"^\s*(?:\[[^\]]+\]|[0-9]{1,4}\.[ \t]+\S|\p{Lu}[\p{L}'’\-]*,\s*\p{Lu}|(?:\p{Lu}[\p{L}'’.\-]*\s+){1,4}\p{Lu}[\p{L}'’\-]*[,.])"#,
            options: .regularExpression) != nil
    }

    static func candidates(destinationPoint: CGPoint, on page: PDFPage) -> [CitationReferenceEntryCandidate] {
        guard isUsableDestinationPoint(destinationPoint, on: page) else { return [] }
        let lines = pageLines(on: page)
        let columns = columnLines(lines, pageBounds: page.bounds(for: .cropBox))
        return columns.enumerated().compactMap { index, column in
            let physicalLines = mergeFragmentsOnBaselines(column)
            guard let origin = physicalLines.filter({ abs($0.bounds.maxY - destinationPoint.y) <= destinationTolerance })
                .map({ $0.bounds.minX }).min() else { return nil }
            let starts = physicalLines.indices.filter {
                physicalLines[$0].bounds.minX <= origin + startIndentTolerance
            }
            guard let start = starts.min(by: {
                max(physicalLines[$0].bounds.minY - destinationPoint.y, destinationPoint.y - physicalLines[$0].bounds.maxY, 0)
                    < max(physicalLines[$1].bounds.minY - destinationPoint.y, destinationPoint.y - physicalLines[$1].bounds.maxY, 0)
            }), abs(destinationPoint.y - physicalLines[start].bounds.maxY) <= destinationTolerance
            else { return nil }
            let next = starts.first(where: { $0 > start && isReferenceStart(physicalLines[$0].text) }) ?? physicalLines.endIndex
            var entryLines = Array(physicalLines[start..<next])
            if next == physicalLines.endIndex, index + 1 < columns.count {
                let continuation = mergeFragmentsOnBaselines(columns[index + 1])
                if let nextOrigin = continuation.map({ $0.bounds.minX }).min() {
                    entryLines += continuation.prefix { $0.bounds.minX > nextOrigin + startIndentTolerance || !isReferenceStart($0.text) }
                }
            }
            let rawText = normalized(entryLines.map(\.text).joined(separator: " "))
            guard !rawText.isEmpty else { return nil }
            return CitationReferenceEntryCandidate(columnIndex: index, lines: entryLines, rawText: rawText)
        }
    }

    static func isInBibliographyRegion(_ bounds: CGRect, on page: PDFPage) -> Bool {
        let lines = pageLines(on: page)
        let pageLayout = layout(of: lines, pageBounds: page.bounds(for: .cropBox))
        func column(_ rect: CGRect) -> Int {
            guard case let .twoColumns(splitX) = pageLayout else { return 0 }
            return rect.minX >= splitX ? 1 : 0
        }
        return lines.contains { heading in
            guard heading.text.range(of: #"(?i)^\s*(?:references|bibliography)\s*$"#, options: .regularExpression) != nil else { return false }
            return column(heading.bounds) < column(bounds)
                || (column(heading.bounds) == column(bounds) && bounds.maxY <= heading.bounds.minY + 2)
        }
    }
    private static func pageLines(on page: PDFPage) -> [CitationTextLine] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap {
            let text = normalized($0.string ?? "")
            guard !text.isEmpty else { return nil }
            let bounds = $0.bounds(for: page)
            if bounds.minY < page.bounds(for: .cropBox).minY + 50,
               text.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { return nil }
            return CitationTextLine(text: text, bounds: $0.bounds(for: page))
        }
    }

    private static func columnLines(_ lines: [CitationTextLine], pageBounds: CGRect) -> [[CitationTextLine]] {
        switch layout(of: lines, pageBounds: pageBounds) {
        case .singleColumn:
            return [lines]
        case let .twoColumns(splitX):
            return [
                lines.filter { $0.bounds.midX < splitX && $0.bounds.maxX <= splitX + 4 },
                lines.filter { $0.bounds.midX >= splitX && $0.bounds.minX >= splitX - 4 },
            ]
        }
    }

    private static func mergeFragmentsOnBaselines(_ lines: [CitationTextLine]) -> [CitationTextLine] {
        let ordered = lines.sorted {
            if abs($0.bounds.midY - $1.bounds.midY) > baselineTolerance {
                return $0.bounds.midY > $1.bounds.midY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
        var merged: [CitationTextLine] = []
        for line in ordered {
            if let last = merged.last, abs(last.bounds.midY - line.bounds.midY) <= baselineTolerance {
                let separator = last.bounds.maxX + 1 < line.bounds.minX ? " " : ""
                merged[merged.count - 1] = CitationTextLine(
                    text: normalized(last.text + separator + line.text),
                    bounds: last.bounds.union(line.bounds)
                )
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class CitationPreviewResolver {
    private let document: PDFDocument

    init(document: PDFDocument) {
        self.document = document
    }

    func resolve(_ link: ReaderLink) -> LinkHintResolution {
        guard case .goTo = link.target,
              let sourcePage = document.page(at: link.sourcePageIndex),
              let selected = matchingAnnotation(for: link, on: sourcePage)
        else { return .activate(link.target) }

        let selectedMarker = marker(for: selected, on: sourcePage)
        let numericMarker = selectedMarker?.marker
        if numericMarker.map({ (1900...2099).contains($0) }) ?? true,
           let sourceGroup = reconstructedAuthorYearGroup(containing: selected, on: sourcePage) {
            return .preview(sourceGroup)
        }

        if let selectedMarker,
           let sourceGroup = reconstructedSourceGroup(
                containing: selectedMarker,
                around: selected.bounds,
                on: sourcePage
           ) {
            // A verified member establishes bibliography role; bracketed equations alone do not.
            if sourceGroup.items.contains(where: \.isResolved) {
                return .preview(sourceGroup)
            }
        }

        if let selectedMarker, let item = baselineNumericItem(for: selectedMarker, annotation: selected, on: sourcePage) {
            return .preview(CitationPreviewGroup(items: [item], selectedIndex: 0))
        }
        if let group = opaqueSourceGroup(containing: selected, on: sourcePage) { return .preview(group) }
        return .activate(link.target)
    }

    private func baselineNumericItem(for marker: CitationMarker, annotation selected: PDFAnnotation, on page: PDFPage) -> CitationPreviewItem? {
        guard case let .goTo(targetPageIndex, targetPoint?) = marker.destination,
              let targetPage = document.page(at: targetPageIndex),
              CitationReferenceEntryExtractor.isInBibliographyRegion(CGRect(origin: targetPoint, size: .zero), on: targetPage),
              let text = page.string,
              let lines = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine()
        else { return nil }
        let wrappers = try! NSRegularExpression(pattern: CitationPreviewClassifier.groupPattern)
        guard !wrappers.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).contains(where: {
            guard let selection = page.selection(for: $0.range) else { return false }
            return selectionIntersects(selection, bounds: selected.bounds, on: page)
        }), lines.contains(where: {
            let bounds = $0.bounds(for: page)
            return abs(bounds.midY - selected.bounds.midY) <= 2 && bounds.height <= selected.bounds.height * 1.5
                && ($0.string ?? "").rangeOfCharacter(from: .letters) != nil
        }) else { return nil }
        let item = previewItem(for: marker)
        return item.isResolved && item.referenceText.hasPrefix("[\(marker.marker)]") ? item : nil
    }
    private func opaqueSourceGroup(containing selected: PDFAnnotation, on page: PDFPage) -> CitationPreviewGroup? {
        guard let text = page.string else { return nil }
        let label = #"[A-Za-z][A-Za-z0-9+._-]*"#
        let contents = label + #"(?:\s*[,;]\s*"# + label + #")*"#
        let pattern = try! NSRegularExpression(pattern: #"(?:\[\s*"# + contents + #"\s*\]|\(\s*"# + contents + #"\s*\))"#)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let selection = page.selection(for: match.range), selectionIntersects(selection, bounds: selected.bounds, on: page),
                  let groupText = selection.string
            else { continue }
            let labels = groupText.trimmingCharacters(in: CharacterSet(charactersIn: "[]() "))
                .components(separatedBy: CharacterSet(charactersIn: ",;"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let annotations = page.annotations.filter { selectionIntersects(selection, bounds: $0.bounds, on: page) }
            var consumed = Set<Int>()
            var selectedIndex: Int?
            let items = labels.enumerated().map { index, label -> CitationPreviewItem in
                let annotationIndex = annotations.indices.first { candidate in
                    !consumed.contains(candidate) && (page.selection(for: annotations[candidate].bounds)?.string ?? "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[]() ").union(.whitespacesAndNewlines)) == label
                }
                guard let annotationIndex else {
                    return CitationPreviewItem(label: label, destination: nil, referenceText: "", state: .unresolved(reason: .missingTarget))
                }
                consumed.insert(annotationIndex)
                let annotation = annotations[annotationIndex]
                if Self.rect(annotation.bounds, matches: selected.bounds) { selectedIndex = index }
                let target = Self.linkTarget(annotation)
                guard case let .goTo(pageIndex, point?) = target, let destinationPage = document.page(at: pageIndex),
                      let candidate = CitationReferenceEntryExtractor.entry(destinationPoint: point, on: destinationPage)
                else { return CitationPreviewItem(label: label, destination: target, referenceText: "", state: .unresolved(reason: .referenceUnavailable)) }
                let escaped = NSRegularExpression.escapedPattern(for: label)
                let matchesLabel = candidate.rawText.range(of: #"^\s*[\[(]"# + escaped + #"[\])]"#, options: .regularExpression) != nil
                let bibliographyHeading = candidate.lines.first.map {
                    CitationReferenceEntryExtractor.isInBibliographyRegion($0.bounds, on: destinationPage)
                } ?? false
                let bibliographyContent = candidate.rawText.range(of: #"https?:\s*//|\b(?:19|20)[0-9]{2}\b"#, options: .regularExpression) != nil
                let hasDifferentLabel = !matchesLabel && candidate.rawText.range(of: #"^\s*[\[(][^\])]+[\])]"#, options: .regularExpression) != nil
                guard matchesLabel || (!hasDifferentLabel && bibliographyHeading && bibliographyContent) else {
                    return CitationPreviewItem(label: label, destination: target, referenceText: "", state: .unresolved(reason: .referenceUnavailable))
                }
                return CitationPreviewItem(label: label, destination: target, referenceText: candidate.rawText)
            }
            guard let selectedIndex, items.contains(where: \.isResolved) else { continue }
            return CitationPreviewGroup(items: items, selectedIndex: selectedIndex)
        }
        return nil
    }
    private func reconstructedSourceGroup(
        containing selectedMarker: CitationMarker,
        around selectedBounds: CGRect,
        on page: PDFPage
    ) -> CitationPreviewGroup? {
        guard let text = page.string else { return nil }
        let pattern = try! NSRegularExpression(
            pattern: CitationPreviewClassifier.groupPattern
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let selection = page.selection(for: match.range),
                  let groupText = selection.string,
                  let numbers = CitationPreviewClassifier.bracketedGroups(in: groupText).first
            else { continue }
            func contains(_ bounds: CGRect) -> Bool {
                selectionIntersects(selection, bounds: bounds, on: page)
            }
            guard contains(selectedBounds) else { continue }
            let candidates = page.annotations.compactMap { annotation -> CitationMarker? in
                guard contains(annotation.bounds) else { return nil }
                return marker(for: annotation, on: page)
            }.sorted(by: Self.sourceReadingOrder)
            var consumed = Set<Int>()
            var selectedIndex: Int?
            let items = numbers.enumerated().map { index, number -> CitationPreviewItem in
                let matches = candidates.indices.filter { !consumed.contains($0) && candidates[$0].marker == number }
                guard let match = matches.first else {
                    if groupText.rangeOfCharacter(from: CharacterSet(charactersIn: "-–−")) != nil,
                       let item = intermediateItem(number: number, candidates: candidates) { return item }
                    return CitationPreviewItem(label: "[\(number)]", destination: nil, referenceText: "", state: .unresolved(reason: .missingTarget))
                }
                consumed.insert(match)
                if Self.markersMatch(candidates[match], selectedMarker) { selectedIndex = index }
                return previewItem(for: candidates[match])
            }
            guard let selectedIndex, consumed.count == candidates.count else { continue }
            return CitationPreviewGroup(items: items, selectedIndex: selectedIndex, sourceContext: CitationPreviewClassifier.sourceContext(in: groupText))
        }
        return nil
    }

    private func intermediateItem(number: Int, candidates: [CitationMarker]) -> CitationPreviewItem? {
        guard let lower = candidates.filter({ $0.marker < number }).max(by: { $0.marker < $1.marker }),
              let upper = candidates.filter({ $0.marker > number }).min(by: { $0.marker < $1.marker }),
              case let .goTo(lowerPage, lowerPoint?) = lower.destination,
              case let .goTo(upperPage, upperPoint?) = upper.destination,
              lowerPage >= 0, upperPage >= lowerPage, upperPage < document.pageCount,
              upperPage - lowerPage <= 16,
              CitationReferenceEntryExtractor.isUsableDestinationPoint(lowerPoint),
              CitationReferenceEntryExtractor.isUsableDestinationPoint(upperPoint)
        else { return nil }
        var entries: [(number: Int, page: Int, point: CGPoint)] = []
        for index in lowerPage...upperPage {
            guard let page = document.page(at: index) else { return nil }
            entries += CitationReferenceEntryExtractor.numericEntryLocations(on: page).map {
                (number: $0.number, page: index, point: $0.point)
            }
        }
        let starts = entries.indices.filter { entries[$0].number == lower.marker && entries[$0].page == lowerPage && abs(entries[$0].point.y - lowerPoint.y) <= 48 }
        let ends = entries.indices.filter { entries[$0].number == upper.marker && entries[$0].page == upperPage && abs(entries[$0].point.y - upperPoint.y) <= 48 }
        guard starts.count == 1, ends.count == 1, let start = starts.first, let end = ends.first, start < end else { return nil }
        let matches = entries[(start + 1)..<end].filter { $0.number == number }
        guard matches.count == 1, let match = matches.first, let page = document.page(at: match.page),
              let text = referenceText(marker: number, point: match.point, on: page)
        else { return nil }
        return CitationPreviewItem(label: "[\(number)]", destination: .goTo(pageIndex: match.page, point: match.point), referenceText: text)
    }
    private func matchingAnnotation(for link: ReaderLink, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { annotation in
            guard let target = Self.linkTarget(annotation), Self.targetsMatch(target, link.target) else {
                return false
            }
            return Self.rect(link.primaryLabelRect, matches: annotation.bounds)
        }
    }

    private static func targetsMatch(_ lhs: ReaderLinkTarget, _ rhs: ReaderLinkTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.url(lhsURL), .url(rhsURL)):
            return lhsURL == rhsURL
        case let (.goTo(lhsPage, lhsPoint), .goTo(rhsPage, rhsPoint)):
            guard lhsPage == rhsPage else { return false }
            switch (lhsPoint, rhsPoint) {
            case (nil, nil):
                return true
            case let (.some(lhsPoint), .some(rhsPoint)):
                let xMatches = lhsPoint.x == rhsPoint.x || (!lhsPoint.x.isFinite && !rhsPoint.x.isFinite)
                let yMatches = lhsPoint.y == rhsPoint.y || (!lhsPoint.y.isFinite && !rhsPoint.y.isFinite)
                return xMatches && yMatches
            default:
                return false
            }
        default:
            return false
        }
    }

    private static func markersMatch(_ lhs: CitationMarker, _ rhs: CitationMarker) -> Bool {
        lhs.sourcePageIndex == rhs.sourcePageIndex
            && lhs.marker == rhs.marker
            && rect(lhs.sourceBounds, matches: rhs.sourceBounds)
            && targetsMatch(lhs.destination, rhs.destination)
    }

    private func marker(for annotation: PDFAnnotation, on page: PDFPage) -> CitationMarker? {
        guard let target = Self.linkTarget(annotation), case .goTo = target else { return nil }
        let exactText = page.selection(for: annotation.bounds)?.string ?? ""
        let marker: Int
        if let exact = CitationPreviewClassifier.marker(in: exactText) {
            marker = exact
        } else {
            guard let members = CitationPreviewClassifier.bracketedGroups(in: exactText).first,
                  case let .goTo(pageIndex, point?) = target, let destinationPage = document.page(at: pageIndex),
                  CitationReferenceEntryExtractor.isUsableDestinationPoint(point)
            else { return nil }
            let entries = CitationReferenceEntryExtractor.numericEntryLocations(on: destinationPage).filter {
                members.contains($0.number) && abs($0.point.y - point.y) <= 48 && abs($0.point.x - point.x) <= 48
            }.map { entry in
                (number: entry.number, distance: max(entry.bounds.minY - point.y, point.y - entry.bounds.maxY, 0))
            }.sorted { $0.distance < $1.distance }
            guard let first = entries.first else { return nil }
            if entries.count > 1, abs(entries[1].distance - first.distance) < 4 { return nil }
            marker = first.number
        }
        return CitationMarker(
            sourcePageIndex: document.index(for: page),
            sourceBounds: annotation.bounds,
            marker: marker,
            destination: target
        )
    }

    private func previewItem(for marker: CitationMarker) -> CitationPreviewItem {
        guard case let .goTo(pageIndex, point) = marker.destination else {
            return CitationPreviewItem(
                label: "[\(marker.marker)]",
                destination: marker.destination,
                referenceText: "",
                state: .unresolved(reason: .missingTarget)
            )
        }
        guard pageIndex >= 0,
              let point,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex),
              CitationReferenceEntryExtractor.isUsableDestinationPoint(point, on: page)
        else {
            return CitationPreviewItem(
                label: "[\(marker.marker)]",
                destination: marker.destination,
                referenceText: "",
                state: .unresolved(reason: .invalidDestination)
            )
        }
        guard let referenceText = referenceText(marker: marker.marker, point: point, on: page) else {
            return CitationPreviewItem(
                label: "[\(marker.marker)]",
                destination: marker.destination,
                referenceText: "",
                state: .unresolved(reason: .referenceUnavailable)
            )
        }
        return CitationPreviewItem(
            label: "[\(marker.marker)]",
            destination: marker.destination,
            referenceText: referenceText,
            state: .resolved
        )
    }

    private func previewItem(for key: AuthorYearCitationKey, destination: ReaderLinkTarget) -> CitationPreviewItem {
        guard case let .goTo(pageIndex, point?) = destination,
              pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex),
              CitationReferenceEntryExtractor.isUsableDestinationPoint(point, on: page)
        else {
            return CitationPreviewItem(label: key.label, destination: destination,
                referenceText: "", state: .unresolved(reason: .invalidDestination))
        }
        guard let entry = CitationReferenceEntryExtractor.entry(destinationPoint: point, on: page),
              AuthorYearCitationClassifier.validates(key, referenceText: entry.rawText)
        else {
            return CitationPreviewItem(label: key.label, destination: destination,
                referenceText: "", state: .unresolved(reason: .referenceUnavailable))
        }
        return CitationPreviewItem(label: key.label, destination: destination,
            referenceText: entry.rawText, state: .resolved)
    }

    private struct AuthorYearFragment {
        let bounds: CGRect
        let text: String
        let destination: ReaderLinkTarget
    }

    private struct AuthorYearSourceOccurrence {
        let range: NSRange
        let text: String
        let fragments: [AuthorYearFragment]
    }

    private static let authorYearWrapperPattern = try! NSRegularExpression(
        pattern: #"(?:\([^()\[\]]{1,180}\)|\[[^()\[\]]{1,180}\])"#
    )
    private static let authorYearYearPattern = try! NSRegularExpression(
        pattern: #"\b((?:19|20)[0-9]{2}[a-z]?)\b"#,
        options: [.caseInsensitive]
    )

    private func reconstructedAuthorYearGroup(
        containing selected: PDFAnnotation,
        on page: PDFPage
    ) -> CitationPreviewGroup? {
        guard let text = page.string,
              let selectedTarget = Self.linkTarget(selected)
        else { return nil }
        let fragments = authorYearFragments(on: page)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

        for match in Self.authorYearWrapperPattern.matches(in: text, range: fullRange) {
            guard let selection = page.selection(for: match.range),
                  let occurrenceText = substring(in: text, range: match.range)
            else { continue }
            let wrapperBounds = selectionBounds(selection, on: page)
            let selectedIsInside = selectionIntersects(selection, bounds: selected.bounds, on: page)
            let selectedIsAdjacent = Self.sourceFragmentsAreAdjacent(selected.bounds, wrapperBounds)
            var occurrenceFragments = fragments.filter {
                selectionIntersects(selection, bounds: $0.bounds, on: page)
            }
            let selectedText = page.selection(for: selected.bounds)?.string ?? ""
            guard selectedIsInside || (selectedIsAdjacent && Self.sourceReadingOrder(selected.bounds, wrapperBounds) && !containsYear(selectedText)
                && occurrenceFragments.contains { Self.targetsMatch($0.destination, selectedTarget) }
                && !occurrenceFragments.contains { Self.targetsMatch($0.destination, selectedTarget) && hasAuthorText($0.text) })
            else { continue }
            let selectedTargetFragments = fragments.filter {
                Self.targetsMatch($0.destination, selectedTarget)
            }
            if let selectedComponent = sourceComponent(containing: selected.bounds, among: selectedTargetFragments) {
                for fragment in selectedComponent where !occurrenceFragments.contains(where: {
                    Self.rect($0.bounds, matches: fragment.bounds)
                }) {
                    let isSelected = Self.rect(fragment.bounds, matches: selected.bounds)
                    let isAuthorFragment = !containsYear(fragment.text) && hasAuthorText(fragment.text)
                    guard isSelected || (isAuthorFragment && Self.sourceReadingOrder(fragment.bounds, wrapperBounds)
                        && Self.sourceFragmentsAreAdjacent(fragment.bounds, wrapperBounds)
                        && !occurrenceFragments.contains { Self.targetsMatch($0.destination, fragment.destination) && hasAuthorText($0.text) })
                    else { continue }
                    occurrenceFragments.append(fragment)
                }
            }
            let occurrence = AuthorYearSourceOccurrence(
                range: match.range,
                text: occurrenceText,
                fragments: occurrenceFragments
            )
            if let group = authorYearGroup(
                occurrence: occurrence,
                selected: selected,
                page: page,
                sourceText: text
            ) {
                return group
            }
        }

        return bareAuthorYearGroup(
            containing: selected,
            selectedTarget: selectedTarget,
            sourceText: text,
            fragments: fragments,
            on: page
        )
    }

    private func authorYearFragments(on page: PDFPage) -> [AuthorYearFragment] {
        page.annotations.compactMap { annotation in
            guard let destination = Self.linkTarget(annotation),
                  case .goTo = destination,
                  let text = page.selection(for: annotation.bounds)?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return AuthorYearFragment(
                bounds: annotation.bounds,
                text: text,
                destination: destination
            )
        }
    }

    private func authorYearGroup(
        occurrence: AuthorYearSourceOccurrence,
        selected: PDFAnnotation,
        page: PDFPage,
        sourceText: String
    ) -> CitationPreviewGroup? {
        let components = targetComponents(occurrence.fragments).sorted {
            Self.sourceReadingOrder($0[0].bounds, $1[0].bounds)
        }
        guard !components.isEmpty else { return nil }
        let years = Self.authorYearYearPattern.matches(in: occurrence.text,
            range: NSRange(occurrence.text.startIndex..<occurrence.text.endIndex, in: occurrence.text))
        if components.count == 1, years.count > 1, let destination = components[0].first?.destination {
            var start = 0
            var keys: [AuthorYearCitationKey] = []
            for year in years {
                let end = year.range.location + year.range.length
                guard let member = substring(in: occurrence.text, range: NSRange(location: start, length: end - start)) else { return nil }
                let key = AuthorYearCitationClassifier.key(from: [member])
                    ?? keys.last.flatMap { AuthorYearCitationClassifier.key(from: [$0.authors, member]) }
                guard let key else { return nil }
                keys.append(key)
                start = end
            }
            let resolved = keys.map { key in
                previewItem(for: key, destination: destination)
            }
            let matches = resolved.indices.filter { resolved[$0].isResolved }
            guard matches.count == 1, let selectedIndex = matches.first else { return nil }
            let items = keys.indices.map { index in
                index == selectedIndex ? resolved[index] : CitationPreviewItem(label: keys[index].label, destination: nil,
                    referenceText: "", state: .unresolved(reason: .missingTarget))
            }
            return CitationPreviewGroup(items: items, selectedIndex: selectedIndex,
                sourceContext: CitationPreviewClassifier.sourceContext(in: occurrence.text))
        }
        var previousKey: AuthorYearCitationKey?
        var selectedIndex: Int?
        let items = components.enumerated().map { index, component -> CitationPreviewItem in
            if component.contains(where: { Self.rect($0.bounds, matches: selected.bounds) }) {
                selectedIndex = index
            }
            let fragmentText = component.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "[](),; ").union(.whitespacesAndNewlines))
            let key: AuthorYearCitationKey?
            if let previousKey, fragmentText.range(of: #"^[a-z]$"#, options: .regularExpression) != nil {
                key = AuthorYearCitationKey(authors: previousKey.authors,
                    year: previousKey.year, yearSuffix: fragmentText)
            } else if let previousKey, AuthorYearCitationClassifier.isYearFragment(fragmentText) {
                key = AuthorYearCitationClassifier.key(from: [previousKey.authors, fragmentText])
            } else {
                key = authorYearKey(for: component, occurrence: occurrence, sourceText: sourceText, page: page)
            }
            guard let key else {
                previousKey = nil
                return CitationPreviewItem(label: fragmentText, destination: component[0].destination,
                    referenceText: "", state: .unresolved(reason: .referenceUnavailable))
            }
            previousKey = key
            return previewItem(for: key, destination: component[0].destination)
        }
        guard let selectedIndex, items.contains(where: \.isResolved) else { return nil }
        return CitationPreviewGroup(items: items, selectedIndex: selectedIndex, sourceContext: CitationPreviewClassifier.sourceContext(in: occurrence.text))
    }

    private func bareAuthorYearGroup(
        containing selected: PDFAnnotation,
        selectedTarget: ReaderLinkTarget,
        sourceText: String,
        fragments: [AuthorYearFragment],
        on page: PDFPage
    ) -> CitationPreviewGroup? {
        let fullRange = NSRange(sourceText.startIndex..<sourceText.endIndex, in: sourceText)
        let wrappedRanges = Self.authorYearWrapperPattern.matches(in: sourceText, range: fullRange).map(\.range)
        let yearMatches = Self.authorYearYearPattern.matches(in: sourceText, range: fullRange)
        let targetFragments = fragments.filter { Self.targetsMatch($0.destination, selectedTarget) }
        guard let sourceComponent = sourceComponent(containing: selected.bounds, among: targetFragments) else { return nil }

        for match in yearMatches.sorted(by: {
            yearDistance($0.range, to: sourceComponent, page: page)
                < yearDistance($1.range, to: sourceComponent, page: page)
        }) {
            let globalYearRange = match.range
            guard !wrappedRanges.contains(where: { NSIntersectionRange($0, globalYearRange).length > 0 }),
                  let yearToken = substring(in: sourceText, range: globalYearRange),
                  let yearSelection = page.selection(for: globalYearRange),
                  let prefix = substring(
                      in: sourceText,
                      range: NSRange(location: 0, length: globalYearRange.location)
                  ),
                  let author = trailingAuthorPrefix(before: prefix),
                  let key = AuthorYearCitationClassifier.key(from: [author, yearToken])
            else { continue }

            let yearBounds = yearSelection.bounds(for: page)
            guard sourceComponent.contains(where: {
                abs($0.bounds.midY - yearBounds.midY) <= 28
                    && (Self.rect($0.bounds, matches: selected.bounds)
                        || $0.bounds.insetBy(dx: -180, dy: -2).intersects(yearBounds))
            }) else { continue }

            let item = previewItem(for: key, destination: selectedTarget)
            guard item.isResolved else { return nil }
            return CitationPreviewGroup(items: [item], selectedIndex: 0)
        }
        return nil
    }

    private func sourceComponent(
        containing bounds: CGRect,
        among fragments: [AuthorYearFragment]
    ) -> [AuthorYearFragment]? {
        let ordered = fragments.sorted { Self.sourceReadingOrder($0.bounds, $1.bounds) }
        guard let seed = ordered.firstIndex(where: {
            Self.rect($0.bounds, matches: bounds) || $0.bounds.intersects(bounds)
        }) else { return nil }
        var included = Set([seed])
        var changed = true
        while changed {
            changed = false
            for index in ordered.indices where !included.contains(index) {
                guard included.contains(where: { Self.sourceFragmentsAreAdjacent(ordered[$0].bounds, ordered[index].bounds) }) else { continue }
                included.insert(index)
                changed = true
            }
        }
        return ordered.enumerated().compactMap { included.contains($0.offset) ? $0.element : nil }
    }

    private static func sourceFragmentsAreAdjacent(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let (earlier, later) = sourceReadingOrder(lhs, rhs) ? (lhs, rhs) : (rhs, lhs)
        let verticalGap = abs(earlier.midY - later.midY)
        if verticalGap <= 4 {
            return max(0, later.minX - earlier.maxX) <= 36
        }
        guard verticalGap <= 20 else { return false }
        return earlier.maxX >= later.minX - 8 || abs(earlier.minX - later.minX) <= 36
    }

    private func targetComponents(_ fragments: [AuthorYearFragment]) -> [[AuthorYearFragment]] {
        var groups: [[AuthorYearFragment]] = []
        for fragment in fragments {
            guard let index = groups.lastIndex(where: {
                guard let first = $0.first else { return false }
                return Self.targetsMatch(first.destination, fragment.destination)
            }) else {
                groups.append([fragment])
                continue
            }
            if groups[index].contains(where: { containsYear($0.text) }) && containsYear(fragment.text) {
                groups.append([fragment])
            } else {
                groups[index].append(fragment)
            }
        }
        return groups.map { $0.sorted { Self.sourceReadingOrder($0.bounds, $1.bounds) } }
    }

    private func authorYearKey(
        for component: [AuthorYearFragment],
        occurrence: AuthorYearSourceOccurrence,
        sourceText: String,
        page: PDFPage
    ) -> AuthorYearCitationKey? {
        if let key = AuthorYearCitationClassifier.key(from: component.map(\.text)) {
            return key
        }
        let localRange = NSRange(occurrence.text.startIndex..<occurrence.text.endIndex, in: occurrence.text)
        let yearMatches = Self.authorYearYearPattern.matches(in: occurrence.text, range: localRange)
        guard !yearMatches.isEmpty else { return nil }
        let occurrenceRange = occurrence.range
        let selectedYear = yearMatches.min { lhs, rhs in
            let lhsRange = NSRange(
                location: occurrenceRange.location + lhs.range.location,
                length: lhs.range.length
            )
            let rhsRange = NSRange(
                location: occurrenceRange.location + rhs.range.location,
                length: rhs.range.length
            )
            return yearDistance(lhsRange, to: component, page: page)
                < yearDistance(rhsRange, to: component, page: page)
        }
        guard let selectedYear else { return nil }
        let precedingYear = yearMatches
            .filter { $0.range.location < selectedYear.range.location }
            .max { $0.range.location < $1.range.location }
        let memberStart = precedingYear.map { $0.range.location + $0.range.length }
            ?? (occurrence.text.first == "(" || occurrence.text.first == "[" ? 1 : 0)
        let memberLength = selectedYear.range.location + selectedYear.range.length - memberStart
        guard memberLength > 0,
              let memberText = substring(
                  in: occurrence.text,
                  range: NSRange(location: memberStart, length: memberLength)
              )
        else { return nil }
        if let key = AuthorYearCitationClassifier.key(from: [memberText]) {
            return key
        }
        guard let prefix = substring(in: sourceText, range: NSRange(location: 0, length: occurrence.range.location)),
              let author = trailingAuthorPrefix(before: prefix)
        else { return nil }
        return AuthorYearCitationClassifier.key(from: [author, memberText])
    }

    private func yearDistance(
        _ range: NSRange,
        to component: [AuthorYearFragment],
        page: PDFPage
    ) -> CGFloat {
        guard let selection = page.selection(for: range) else { return .greatestFiniteMagnitude }
        let bounds = selection.bounds(for: page)
        return component.map {
            abs($0.bounds.midX - bounds.midX) + abs($0.bounds.midY - bounds.midY)
        }.min() ?? .greatestFiniteMagnitude
    }

    private func trailingAuthorPrefix(before text: String) -> String? {
        let tokens = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
        guard !tokens.isEmpty else { return nil }
        let connectors = Set(["et", "al.", "al", "and", "&"])
        let stopWords = Set([
            "a", "an", "the", "against", "as", "at", "by", "for", "from", "in", "into", "of",
            "on", "or", "that", "to", "with", "since", "provided", "while", "we", "our"
        ])
        var accepted: [String] = []
        for rawToken in tokens.reversed() {
            if rawToken == "&", !accepted.isEmpty { accepted.append("&"); continue }
            let token = String(rawToken).trimmingCharacters(in: .punctuationCharacters)
            let folded = token.lowercased()
            guard !token.isEmpty, token.rangeOfCharacter(from: .letters) != nil else { break }
            let isConnector = connectors.contains(folded)
            let startsUppercase = token.first?.isUppercase == true
            guard isConnector || startsUppercase else { break }
            if accepted.isEmpty, stopWords.contains(folded) { break }
            accepted.append(folded == "al" && rawToken.hasSuffix(".") ? "al." : token)
            if accepted.count == 8 { break }
        }
        let result = accepted.reversed().joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    private func substring(in text: String, range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func selectionBounds(_ selection: PDFSelection, on page: PDFPage) -> CGRect {
        let pieces = selection.selectionsByLine().map { $0.bounds(for: page) }
        return pieces.dropFirst().reduce(pieces.first ?? selection.bounds(for: page)) { $0.union($1) }
    }

    private func selectionIntersects(_ selection: PDFSelection, bounds: CGRect, on page: PDFPage) -> Bool {
        let pieces = selection.selectionsByLine().map { $0.bounds(for: page) }
        if pieces.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(CGPoint(x: bounds.midX, y: bounds.midY)) }) { return true }
        guard pieces.count > 1, let maximumLineHeight = pieces.map(\.height).max(), bounds.height > maximumLineHeight * 1.5,
              let annotationText = page.selection(for: bounds)?.string, let selectedText = selection.string
        else { return false }
        return annotationText.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            == selectedText.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private func containsYear(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.authorYearYearPattern.firstMatch(in: text, range: range) != nil
    }

    private func hasAuthorText(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutYears = Self.authorYearYearPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        return withoutYears.rangeOfCharacter(from: .letters) != nil
    }

    private func referenceText(marker: Int, point: CGPoint, on page: PDFPage) -> String? {
        return CitationReferenceEntryExtractor.numericEntry(
            marker: marker,
            destinationPoint: point,
            on: page
        )
    }

    private static func linkTarget(_ annotation: PDFAnnotation) -> ReaderLinkTarget? {
        if let action = annotation.action as? PDFActionGoTo {
            return destinationTarget(action.destination)
        }
        if let destination = annotation.destination {
            return destinationTarget(destination)
        }
        if let action = annotation.action as? PDFActionURL, let url = action.url {
            return .url(url.absoluteString)
        }
        if let url = annotation.url { return .url(url.absoluteString) }
        return nil
    }

    private static func destinationTarget(_ destination: PDFDestination) -> ReaderLinkTarget? {
        guard let page = destination.page, let document = page.document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }
        return .goTo(pageIndex: pageIndex, point: destination.point)
    }

    private static func sourceReadingOrder(_ lhs: CitationMarker, _ rhs: CitationMarker) -> Bool {
        sourceReadingOrder(lhs.sourceBounds, rhs.sourceBounds)
    }

    private static func sourceReadingOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if abs(lhs.midY - rhs.midY) > 4 { return lhs.midY > rhs.midY }
        return lhs.minX < rhs.minX
    }

    private static func rect(_ lhs: CGRect, matches rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5
            && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5
            && abs(lhs.height - rhs.height) <= 0.5
    }
}
