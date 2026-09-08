import Foundation
import PDFKit
import PDFReaderCore

struct CitationMarker: Equatable {
    let sourcePageIndex: Int
    let sourceBounds: CGRect
    let marker: Int
    let destination: ReaderLinkTarget
}

struct AuthorYearCitationMarker: Equatable {
    let sourceBounds: CGRect
    let key: AuthorYearCitationKey
    let destination: ReaderLinkTarget
    let containsSelectedAnnotation: Bool
    let sourceFragments: [CGRect]
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
    let destination: ReaderLinkTarget
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
        destination: ReaderLinkTarget,
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
}

enum LinkHintResolution: Equatable {
    case activate(ReaderLinkTarget)
    case preview(CitationPreviewGroup)
}

struct AuthorYearCitationKey: Equatable {
    let authors: String
    let primarySurname: String
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
        let text = joinFragments(fragments)
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
        authors = authors
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "(),;")))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard authors.rangeOfCharacter(from: .letters) != nil,
              !authors.lowercased().hasPrefix("et al")
        else { return nil }
        let primarySurname = authors.split(whereSeparator: { $0.isWhitespace }).first
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        guard primarySurname.rangeOfCharacter(from: .letters) != nil else { return nil }
        return AuthorYearCitationKey(
            authors: authors,
            primarySurname: primarySurname,
            year: year,
            yearSuffix: suffix
        )
    }

    static func validates(_ key: AuthorYearCitationKey, referenceText: String) -> Bool {
        let foldedReference = folded(referenceText)
        let foldedSurname = folded(key.primarySurname)
        guard foldedReference.hasPrefix(foldedSurname) else { return false }
        let yearToken = "\(key.year)\(key.yearSuffix)"
        let pattern = try! NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: yearToken) + #"\b"#)
        let range = NSRange(foldedReference.startIndex..<foldedReference.endIndex, in: foldedReference)
        return pattern.firstMatch(in: foldedReference, range: range) != nil
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

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CitationPreviewClassifier {
    private static let exactMarker = try! NSRegularExpression(pattern: #"^\s*(?:([0-9]{1,4})|\[\s*([0-9]{1,4})\s*\])\s*$"#)
    private static let bracketedGroup = try! NSRegularExpression(
        pattern: #"\[\s*[0-9]{1,4}(?:\s*[,;]\s*[0-9]{1,4})*\s*\]"#
    )
    private static let number = try! NSRegularExpression(pattern: #"[0-9]{1,4}"#)

    static func marker(in exactSourceText: String) -> Int? {
        let range = NSRange(exactSourceText.startIndex..<exactSourceText.endIndex, in: exactSourceText)
        guard let match = exactMarker.firstMatch(in: exactSourceText, range: range),
              let markerRange = Range(match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1), in: exactSourceText)
        else { return nil }
        return Int(exactSourceText[markerRange])
    }

    static func bracketedGroups(in sourceContext: String) -> [[Int]] {
        let range = NSRange(sourceContext.startIndex..<sourceContext.endIndex, in: sourceContext)
        return bracketedGroup.matches(in: sourceContext, range: range).compactMap { match in
            guard let groupRange = Range(match.range, in: sourceContext) else { return nil }
            let group = String(sourceContext[groupRange])
            let groupNSRange = NSRange(group.startIndex..<group.endIndex, in: group)
            let markers = number.matches(in: group, range: groupNSRange).compactMap { numberMatch -> Int? in
                guard let swiftRange = Range(numberMatch.range, in: group) else { return nil }
                return Int(group[swiftRange])
            }
            return markers.isEmpty ? nil : markers
        }
    }

    static func bracketedMarkers(in sourceContext: String, containing selectedMarker: Int) -> [Int]? {
        bracketedGroups(in: sourceContext).first { $0.contains(selectedMarker) }
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
            if accepted.count == maximumLines { break }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if !accepted.isEmpty, nextMarkerPattern.firstMatch(in: text, range: range) != nil { break }
            if let previousBounds, previousBounds.minY - line.bounds.maxY > maximumLineGap { break }
            let candidate = (accepted + [text]).joined(separator: " ")
            if candidate.count > maximumCharacters { break }
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

    static func layout(of lines: [CitationTextLine], pageBounds: CGRect) -> CitationReferencePageLayout {
        let midpoint = pageBounds.midX
        let usable = lines.filter { $0.bounds.width >= 20 && $0.bounds.height <= 24 }
        let left = usable.filter { $0.bounds.midX < midpoint && $0.bounds.maxX <= midpoint + 4 }
        let right = usable.filter { $0.bounds.midX >= midpoint && $0.bounds.minX >= midpoint - 4 }
        guard left.count >= 3, right.count >= 3 else { return .singleColumn }
        let pairedBaselines = left.reduce(into: 0) { count, lhs in
            if right.contains(where: { abs($0.bounds.midY - lhs.bounds.midY) <= baselineTolerance }) {
                count += 1
            }
        }
        guard pairedBaselines >= 3 else { return .singleColumn }
        return .twoColumns(splitX: midpoint)
    }

    static func numericEntry(marker: Int, destinationPoint: CGPoint, on page: PDFPage) -> String? {
        guard isUsableDestinationPoint(destinationPoint) else { return nil }
        let lines = pageLines(on: page)
        let columns = columnLines(lines, pageBounds: page.bounds(for: .cropBox))
        let minimumY = destinationPoint.y - 220
        let maximumY = destinationPoint.y + 48
        let matches = columns.compactMap { column -> String? in
            let nearby = column.filter { $0.bounds.maxY >= minimumY && $0.bounds.minY <= maximumY }
            return CitationReferenceExtractor.extract(marker: marker, from: mergeFragmentsOnBaselines(nearby))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func entry(destinationPoint: CGPoint, on page: PDFPage) -> CitationReferenceEntryCandidate? {
        guard isUsableDestinationPoint(destinationPoint) else { return nil }
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

    static func candidates(destinationPoint: CGPoint, on page: PDFPage) -> [CitationReferenceEntryCandidate] {
        guard isUsableDestinationPoint(destinationPoint) else { return [] }
        let lines = pageLines(on: page)
        return columnLines(lines, pageBounds: page.bounds(for: .cropBox)).enumerated().compactMap { index, column in
            let physicalLines = mergeFragmentsOnBaselines(column)
            guard let origin = physicalLines.map({ $0.bounds.minX }).min() else { return nil }
            let starts = physicalLines.indices.filter {
                physicalLines[$0].bounds.minX <= origin + startIndentTolerance
            }
            guard let start = starts.min(by: {
                abs(destinationPoint.y - physicalLines[$0].bounds.maxY)
                    < abs(destinationPoint.y - physicalLines[$1].bounds.maxY)
            }), abs(destinationPoint.y - physicalLines[start].bounds.maxY) <= destinationTolerance
            else { return nil }
            let next = starts.first(where: { $0 > start }) ?? physicalLines.endIndex
            let entryLines = Array(physicalLines[start..<next])
            let rawText = normalized(entryLines.map(\.text).joined(separator: " "))
            guard !rawText.isEmpty else { return nil }
            return CitationReferenceEntryCandidate(columnIndex: index, lines: entryLines, rawText: rawText)
        }
    }

    private static func pageLines(on page: PDFPage) -> [CitationTextLine] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap {
            let text = normalized($0.string ?? "")
            guard !text.isEmpty else { return nil }
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

        if let selectedMarker = marker(for: selected, on: sourcePage),
           let sourceGroup = reconstructedSourceGroup(
                containing: selectedMarker,
                around: selected.bounds,
                on: sourcePage
           ) {
            let items = sourceGroup.map(previewItem(for:))
            // Brackets alone also describe equations, notes and section links.
            // A resolved bibliography member establishes the group's citation role.
            guard items.contains(where: \.isResolved) else { return .activate(link.target) }
            guard let selectedIndex = sourceGroup.firstIndex(where: { Self.markersMatch($0, selectedMarker) }) else {
                return .activate(link.target)
            }
            return .preview(CitationPreviewGroup(items: items, selectedIndex: selectedIndex))
        }

        if let sourceGroup = reconstructedAuthorYearGroup(containing: selected, on: sourcePage) {
            let resolved = sourceGroup.compactMap { marker in
                previewItem(for: marker).map { (marker: marker, item: $0) }
            }
            guard resolved.count == sourceGroup.count,
                  let selectedIndex = resolved.firstIndex(where: { $0.marker.containsSelectedAnnotation })
            else { return .activate(link.target) }
            return .preview(CitationPreviewGroup(items: resolved.map(\.item), selectedIndex: selectedIndex))
        }

        return .activate(link.target)
    }

    private func reconstructedSourceGroup(
        containing selectedMarker: CitationMarker,
        around selectedBounds: CGRect,
        on page: PDFPage
    ) -> [CitationMarker]? {
        guard let text = page.string else { return nil }
        let pattern = try! NSRegularExpression(
            pattern: #"\[\s*[0-9]{1,4}(?:\s*[,;]\s*[0-9]{1,4})*\s*\]"#
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let selection = page.selection(for: match.range),
                  let groupText = selection.string,
                  let numbers = CitationPreviewClassifier.bracketedGroups(in: groupText).first
            else { continue }
            let fragments = selection.selectionsByLine().map { $0.bounds(for: page) }
            func contains(_ bounds: CGRect) -> Bool {
                fragments.contains { fragment in
                    fragment.insetBy(dx: -1, dy: -1).contains(CGPoint(x: bounds.midX, y: bounds.midY))
                }
            }
            guard contains(selectedBounds) else { continue }
            let candidates = page.annotations.compactMap { annotation -> CitationMarker? in
                guard contains(annotation.bounds) else { return nil }
                return marker(for: annotation, on: page)
            }.sorted(by: Self.sourceReadingOrder)
            guard candidates.map(\.marker) == numbers,
                  candidates.contains(where: { Self.markersMatch($0, selectedMarker) })
            else { continue }
            return candidates
        }
        return nil
    }

    private func matchingAnnotation(for link: ReaderLink, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { annotation in
            guard let target = Self.linkTarget(annotation), Self.targetsMatch(target, link.target) else {
                return false
            }
            return link.rects.contains { Self.rect($0, matches: annotation.bounds) }
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
        guard let marker = CitationPreviewClassifier.marker(in: exactText) else { return nil }
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
              CitationReferenceEntryExtractor.isUsableDestinationPoint(point),
              let page = document.page(at: pageIndex)
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

    private func previewItem(for marker: AuthorYearCitationMarker) -> CitationPreviewItem? {
        guard case let .goTo(pageIndex, point?) = marker.destination,
              pageIndex >= 0,
              pageIndex < document.pageCount,
              CitationReferenceEntryExtractor.isUsableDestinationPoint(point),
              let page = document.page(at: pageIndex),
              let entry = CitationReferenceEntryExtractor.entry(destinationPoint: point, on: page),
              AuthorYearCitationClassifier.validates(marker.key, referenceText: entry.rawText)
        else { return nil }
        return CitationPreviewItem(
            label: marker.key.label,
            destination: marker.destination,
            referenceText: entry.rawText,
            state: .resolved
        )
    }

    private func reconstructedAuthorYearGroup(
        containing selected: PDFAnnotation,
        on page: PDFPage
    ) -> [AuthorYearCitationMarker]? {
        let pageBounds = page.bounds(for: .cropBox)
        let midpoint = pageBounds.midX
        let columnBounds = selected.bounds.midX < midpoint
            ? CGRect(
                x: pageBounds.minX,
                y: pageBounds.minY,
                width: midpoint - pageBounds.minX,
                height: pageBounds.height
            )
            : CGRect(
                x: midpoint,
                y: pageBounds.minY,
                width: pageBounds.maxX - midpoint,
                height: pageBounds.height
            )
        let verticalPadding: CGFloat = 20
        let verticalBounds = CGRect(
            x: columnBounds.minX,
            y: selected.bounds.minY - verticalPadding,
            width: columnBounds.width,
            height: selected.bounds.height + verticalPadding * 2
        ).intersection(pageBounds)

        let annotations = page.annotations.filter { annotation in
            guard annotation.bounds.intersects(verticalBounds),
                  let target = Self.linkTarget(annotation),
                  case .goTo = target
            else { return false }
            return true
        }
        var groups: [(destination: ReaderLinkTarget, annotations: [PDFAnnotation])] = []
        for annotation in annotations {
            guard let destination = Self.linkTarget(annotation) else { continue }
            if let index = groups.firstIndex(where: { $0.destination == destination }) {
                groups[index].annotations.append(annotation)
            } else {
                groups.append((destination, [annotation]))
            }
        }

        let markers = groups.compactMap { group -> AuthorYearCitationMarker? in
            let ordered = group.annotations.sorted { Self.sourceReadingOrder($0.bounds, $1.bounds) }
            let fragments = ordered.map { page.selection(for: $0.bounds)?.string ?? "" }
            guard let key = AuthorYearCitationClassifier.key(from: fragments) else { return nil }
            let bounds = ordered.dropFirst().reduce(ordered[0].bounds) { $0.union($1.bounds) }
            return AuthorYearCitationMarker(
                sourceBounds: bounds,
                key: key,
                destination: group.destination,
                containsSelectedAnnotation: ordered.contains { Self.rect($0.bounds, matches: selected.bounds) },
                sourceFragments: ordered.map(\.bounds)
            )
        }.sorted { Self.sourceReadingOrder($0.sourceBounds, $1.sourceBounds) }

        guard let selectedIndex = markers.firstIndex(where: \.containsSelectedAnnotation) else { return nil }
        let sourceLineBounds = page.selection(for: verticalBounds)?.selectionsByLine().map {
            $0.bounds(for: page)
        } ?? []
        let contentMinX = sourceLineBounds.map(\.minX).min() ?? columnBounds.minX
        let contentMaxX = sourceLineBounds.map(\.maxX).max() ?? columnBounds.maxX
        var lowerBound = selectedIndex
        while lowerBound > 0,
              Self.authorYearMarkersAreAdjacent(
                markers[lowerBound - 1],
                markers[lowerBound],
                contentMinX: contentMinX,
                contentMaxX: contentMaxX
              ) {
            lowerBound -= 1
        }
        var upperBound = selectedIndex
        while upperBound + 1 < markers.count,
              Self.authorYearMarkersAreAdjacent(
                markers[upperBound],
                markers[upperBound + 1],
                contentMinX: contentMinX,
                contentMaxX: contentMaxX
              ) {
            upperBound += 1
        }
        let result = Array(markers[lowerBound...upperBound])
        let matchedFragments = markers.flatMap(\.sourceFragments)
        let hasAdjacentUnmatchedYear = annotations.contains { annotation in
            let isMatched = matchedFragments.contains { Self.rect($0, matches: annotation.bounds) }
            guard !isMatched,
                  let text = page.selection(for: annotation.bounds)?.string,
                  AuthorYearCitationClassifier.isYearFragment(text)
            else { return false }
            return result.flatMap(\.sourceFragments).contains {
                Self.sourceFragmentsAreAdjacent(
                    $0,
                    annotation.bounds,
                    contentMinX: contentMinX,
                    contentMaxX: contentMaxX
                )
            }
        }
        guard !hasAdjacentUnmatchedYear else { return nil }
        return result
    }

    private func referenceText(marker: Int, point: CGPoint, on page: PDFPage) -> String? {
        guard CitationReferenceEntryExtractor.isUsableDestinationPoint(point) else { return nil }
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

    private static func authorYearMarkersAreAdjacent(
        _ lhs: AuthorYearCitationMarker,
        _ rhs: AuthorYearCitationMarker,
        contentMinX: CGFloat,
        contentMaxX: CGFloat
    ) -> Bool {
        guard let lhsLast = lhs.sourceFragments.last, let rhsFirst = rhs.sourceFragments.first else { return false }
        return sourceFragmentsAreAdjacent(
            lhsLast,
            rhsFirst,
            contentMinX: contentMinX,
            contentMaxX: contentMaxX
        )
    }
    private static func sourceFragmentsAreAdjacent(
        _ lhs: CGRect,
        _ rhs: CGRect,
        contentMinX: CGFloat,
        contentMaxX: CGFloat
    ) -> Bool {
        let (earlier, later) = sourceReadingOrder(lhs, rhs) ? (lhs, rhs) : (rhs, lhs)
        if abs(earlier.midY - later.midY) <= 4 {
            return max(0, later.minX - earlier.maxX) <= 30
        }
        let lineGap = earlier.midY - later.midY
        return lineGap > 4
            && lineGap <= 18
            && earlier.maxX >= contentMaxX - 8
            && later.minX <= contentMinX + 8
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
