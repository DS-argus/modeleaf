import AppKit

enum ApplicationIcon {
    static func load() -> NSImage? {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle.main
        #endif

        guard let iconURL = resourceBundle.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: iconURL)
    }
}
