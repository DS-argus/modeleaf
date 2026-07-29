import PDFReaderCore

@MainActor
protocol ReaderLinkProviding: AnyObject {
    func linkTargets() -> [RawLink]
    func activateLink(_ target: ReaderLinkTarget)
}
