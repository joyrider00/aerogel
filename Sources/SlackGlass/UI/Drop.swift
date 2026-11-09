import AppKit
import UniformTypeIdentifiers

/// Turns whatever was dragged or pasted into files we own. Screenshot thumbnails hand over a temporary file
/// that's deleted once the drag ends, and some apps send a file promise or raw image data instead of a file,
/// so everything is copied into Slack Glass's own temp folder right away.
enum DropReader {
    static var types: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func canRead(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pb.availableType(from: [.png, .tiff]) != nil
    }

    private static func stash() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlackGlass-attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Calls back on the main thread with local copies (empty if nothing usable was found).
    static func read(_ pb: NSPasteboard, done: @escaping @MainActor ([URL]) -> Void) {
        let dir = stash()
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let copies = urls.map { url -> URL in
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : url
            }
            Task { @MainActor in done(copies) }
            return
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let group = DispatchGroup()
            let lock = NSLock()
            var got: [URL] = []
            for p in promises {
                group.enter()
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    if error == nil { lock.lock(); got.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { MainActor.assumeIsolated { done(got) } }
            return
        }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = dir.appendingPathComponent("Image \(Int(Date().timeIntervalSince1970)).png")
            let ok = (try? png.write(to: url)) != nil
            Task { @MainActor in done(ok ? [url] : []) }
            return
        }
        Task { @MainActor in done([]) }
    }
}

/// The HUD's content view: accepts drops anywhere on the panel (thread, inbox, composer) while a
/// conversation is open, and hands the files to the composer.
final class DropContainerView: NSView {
    var canAccept: () -> Bool = { true }
    var onHover: ((Bool) -> Void)?
    var onFiles: (([URL]) -> Void)?

    init(host: NSView) {
        super.init(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes(DropReader.types)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func accepts(_ info: NSDraggingInfo) -> Bool { canAccept() && DropReader.canRead(info.draggingPasteboard) }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(info)
        onHover?(ok)
        return ok ? .copy : []
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { accepts(info) ? .copy : [] }
    override func draggingExited(_ info: NSDraggingInfo?) { onHover?(false) }
    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool { accepts(info) }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        onHover?(false)
        guard accepts(info) else { return false }
        DropReader.read(info.draggingPasteboard) { [weak self] urls in
            if !urls.isEmpty { self?.onFiles?(urls) }
        }
        return true
    }
}
