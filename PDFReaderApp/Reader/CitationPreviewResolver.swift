import Foundation
import PDFKit
import PDFReaderCore

struct CitationMarker: Equatable {
    let sourcePageIndex: Int
    let sourceBounds: CGRect
    let marker: Int
    let destination: ReaderLinkTarget
}

struct CitationPreviewItem: Equatable {
    let marker: Int
    let destinationPageIndex: Int
    let destinationPoint: CGPoint
    let referenceText: String

    var destination: ReaderLinkTarget {
        .goTo(pageIndex: destinationPageIndex, point: destinationPoint)
    }
}

struct CitationPreviewGroup: Equatable {
    let items: [CitationPreviewItem]
    let selectedIndex: Int
}

enum LinkHintResolution: Equatable {
    case activate(ReaderLinkTarget)
    case preview(CitationPreviewGroup)
}

struct CitationTextLine: Equatable {
    let text: String
    let bounds: CGRect
}

enum CitationPreviewClassifier {
    private static let exactMarker = try! NSRegularExpression(pattern: #"^\s*([0-9]{1,4})\s*$"#)
    private static let bracketedGroup = try! NSRegularExpression(
        pattern: #"\[\s*[0-9]{1,4}(?:\s*[,;]\s*[0-9]{1,4})*\s*\]"#
    )
    private static let number = try! NSRegularExpression(pattern: #"[0-9]{1,4}"#)

    static func marker(in exactSourceText: String) -> Int? {
        let range = NSRange(exactSourceText.startIndex..<exactSourceText.endIndex, in: exactSourceText)
        guard let match = exactMarker.firstMatch(in: exactSourceText, range: range),
              let markerRange = Range(match.range(at: 1), in: exactSourceText)
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
        let markerPattern = try! NSRegularExpression(pattern: #"^\s*\[\s*\#(marker)\s*\](?:\s|$)"#)
        let nextMarkerPattern = try! NSRegularExpression(pattern: #"^\s*\[\s*[0-9]{1,4}\s*\](?:\s|$)"#)
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

@MainActor
final class CitationPreviewResolver {
    private let document: PDFDocument

    init(document: PDFDocument) {
        self.document = document
    }

    func resolve(_ link: ReaderLink) -> LinkHintResolution {
        guard case .goTo = link.target,
              let sourcePage = document.page(at: link.sourcePageIndex),
              let selected = matchingAnnotation(for: link, on: sourcePage),
              let selectedMarker = marker(for: selected, on: sourcePage),
              let sourceGroup = reconstructedSourceGroup(
                containing: selectedMarker,
                around: selected.bounds,
                on: sourcePage
              )
        else { return .activate(link.target) }

        let resolved = sourceGroup.compactMap(previewItem(for:))
        guard let resolvedSelectedIndex = resolved.firstIndex(where: { $0.marker == selectedMarker.marker }) else {
            return .activate(link.target)
        }
        return .preview(CitationPreviewGroup(items: resolved, selectedIndex: resolvedSelectedIndex))
    }

    private func reconstructedSourceGroup(
        containing selectedMarker: CitationMarker,
        around selectedBounds: CGRect,
        on page: PDFPage
    ) -> [CitationMarker]? {
        let pageBounds = page.bounds(for: .cropBox)
        let verticalPadding: CGFloat = 16
        let contextBounds = CGRect(
            x: pageBounds.minX,
            y: selectedBounds.minY - verticalPadding,
            width: pageBounds.width,
            height: selectedBounds.height + (verticalPadding * 2)
        ).intersection(pageBounds)
        guard let context = page.selection(for: contextBounds)?.string else { return nil }
        let groups = CitationPreviewClassifier.bracketedGroups(in: context).sorted { $0.count > $1.count }
        guard !groups.isEmpty else { return nil }

        let candidates = page.annotations.compactMap { annotation -> CitationMarker? in
            guard annotation.bounds.intersects(contextBounds) else { return nil }
            return marker(for: annotation, on: page)
        }.sorted(by: Self.sourceReadingOrder)

        for markers in groups where markers.contains(selectedMarker.marker) {
            guard candidates.count >= markers.count else { continue }
            for start in 0...(candidates.count - markers.count) {
                let candidate = Array(candidates[start..<(start + markers.count)])
                guard candidate.map(\.marker) == markers,
                      candidate.contains(selectedMarker)
                else { continue }
                return candidate
            }
        }
        return nil
    }


    private func matchingAnnotation(for link: ReaderLink, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { annotation in
            guard let target = Self.linkTarget(annotation), target == link.target else { return false }
            return link.rects.contains { Self.rect($0, matches: annotation.bounds) }
        }
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

    private func previewItem(for marker: CitationMarker) -> CitationPreviewItem? {
        guard case let .goTo(pageIndex, point?) = marker.destination,
              let page = document.page(at: pageIndex),
              pageIndex >= 0, pageIndex < document.pageCount,
              let referenceText = referenceText(marker: marker.marker, point: point, on: page)
        else { return nil }
        return CitationPreviewItem(
            marker: marker.marker,
            destinationPageIndex: pageIndex,
            destinationPoint: point,
            referenceText: referenceText
        )
    }

    private func referenceText(marker: Int, point: CGPoint, on page: PDFPage) -> String? {
        let bounds = page.bounds(for: .cropBox)
        let sentinelThreshold = CGFloat(Float.greatestFiniteMagnitude) / 2
        guard point.y.isFinite, abs(point.y) < sentinelThreshold else { return nil }
        let minimumY = max(bounds.minY, point.y - 220)
        let vertical = CGRect(
            x: bounds.minX + 8,
            y: minimumY,
            width: max(1, bounds.width - 16),
            height: min(268, bounds.maxY - minimumY)
        )
        guard let selection = page.selection(for: vertical) else { return nil }
        let lines = selection.selectionsByLine().map {
            CitationTextLine(text: $0.string ?? "", bounds: $0.bounds(for: page))
        }
        return CitationReferenceExtractor.extract(marker: marker, from: lines)
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
        if abs(lhs.sourceBounds.midY - rhs.sourceBounds.midY) > 4 {
            return lhs.sourceBounds.midY > rhs.sourceBounds.midY
        }
        return lhs.sourceBounds.minX < rhs.sourceBounds.minX
    }
    private static func rect(_ lhs: CGRect, matches rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5
            && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5
            && abs(lhs.height - rhs.height) <= 0.5
    }
}
