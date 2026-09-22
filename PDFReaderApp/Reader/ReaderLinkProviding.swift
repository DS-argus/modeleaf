import PDFReaderCore

@MainActor
protocol ReaderLinkProviding: AnyObject {
    func linkTargets() -> [RawLink]
    func resolveLinkHint(_ link: ReaderLink) -> LinkHintResolution
    func activateLink(_ target: ReaderLinkTarget)
}
