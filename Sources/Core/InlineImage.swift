import Foundation
import CoreGraphics
import ImageIO

/// One picture placed in the grid.
///
/// The anchor is a *stable* row — `scrollbackEvicted + absolute row`, the same
/// coordinate the OSC 133 marks use — because an absolute index shifts every
/// time a line falls out of scrollback, and a picture that slides off its own
/// output after ten thousand lines is worse than no picture at all.
///
/// The rows an image covers are real rows in the buffer: placing one feeds as
/// many blank lines as it is tall. That is what keeps scrolling, selection,
/// search, eviction and `BlockLayout` working with no special cases — the
/// image is chrome drawn over rows that exist, not a thing the grid has to
/// know about.
struct InlineImage {

    /// What the pixels are, and where they came from.
    enum Source {
        /// Encoded bytes exactly as the program sent them — PNG, JPEG, GIF,
        /// whatever ImageIO recognises. Kept encoded because that is both
        /// smaller than the bitmap and the form a decoder wants.
        case encoded([UInt8])
        /// Straight RGBA, which is what a Sixel decodes to. There is no
        /// encoded form to keep, and re-encoding pixels we already hold would
        /// cost time to save nothing.
        case bitmap(rgba: [UInt8], width: Int, height: Int)
    }

    let id: Int
    /// Top-left of the picture, in stable rows.
    var stableRow: Int
    /// Column the picture starts at.
    var col: Int
    /// How many cells it covers.
    var cols: Int
    var rows: Int
    /// The picture's own size, for aspect-correct drawing inside those cells.
    var pixelWidth: Int
    var pixelHeight: Int
    var source: Source

    /// What this image costs the store, so the budget can be enforced without
    /// asking each source how big it is.
    var byteCount: Int {
        switch source {
        case .encoded(let bytes):     return bytes.count
        case .bitmap(let rgba, _, _): return rgba.count
        }
    }

    /// The stable rows this picture covers.
    var stableRows: Range<Int> { stableRow..<(stableRow + rows) }
}

/// Every picture on screen or in scrollback, under a memory budget.
///
/// A program can print megabytes of images, by accident or on purpose — `for
/// f in *.png; do imgcat $f; done` in a large directory is not a hostile act
/// and would still exhaust memory without a ceiling here. Oldest goes first,
/// because the newest picture is the one being looked at.
struct InlineImageStore {

    /// The most one picture may weigh. Bigger than any screenshot a phone
    /// takes, small enough that a single sequence cannot blow the budget.
    static let maximumImageBytes = 8 << 20

    /// The most every picture may weigh together.
    static let maximumTotalBytes = 48 << 20

    /// The largest side a picture may have. Beyond this, decoding costs more
    /// than the result can ever show on a screen a few hundred points wide,
    /// and a crafted header claiming 100,000 pixels would allocate for it.
    static let maximumPixelSide = 4096

    private(set) var images: [InlineImage] = []
    private(set) var totalBytes = 0
    private var nextID = 1

    var isEmpty: Bool { images.isEmpty }

    // MARK: - Recording

    /// Adds a picture, evicting older ones if it does not fit. Returns the id
    /// it was given, or nil if the picture is too big to keep at any price.
    @discardableResult
    mutating func insert(stableRow: Int, col: Int, cols: Int, rows: Int,
                         pixelWidth: Int, pixelHeight: Int,
                         source: InlineImage.Source) -> Int? {
        let image = InlineImage(id: nextID, stableRow: stableRow, col: col,
                                cols: cols, rows: rows,
                                pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                source: source)
        guard image.byteCount <= InlineImageStore.maximumImageBytes else { return nil }

        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        images.append(image)
        totalBytes += image.byteCount
        evictToBudget()
        return image.id
    }

    private mutating func evictToBudget() {
        while totalBytes > InlineImageStore.maximumTotalBytes, images.count > 1 {
            totalBytes -= images.removeFirst().byteCount
        }
    }

    // MARK: - Forgetting

    /// Drops pictures whose rows have aged out of scrollback entirely. Called
    /// wherever the shell-integration marks are pruned, and for the same
    /// reason: the text they were drawn against is gone.
    mutating func discard(before oldestStableRow: Int) {
        var freed = 0
        images.removeAll { image in
            let gone = image.stableRows.upperBound <= oldestStableRow
            if gone { freed += image.byteCount }
            return gone
        }
        totalBytes -= freed
    }

    /// Drops pictures overlapping a range of stable rows — what an erase does
    /// to the pictures drawn on the rows it clears.
    mutating func discard(rows: Range<Int>) {
        var freed = 0
        images.removeAll { image in
            let hit = image.stableRows.overlaps(rows)
            if hit { freed += image.byteCount }
            return hit
        }
        totalBytes -= freed
    }

    mutating func removeAll() {
        images.removeAll()
        totalBytes = 0
    }

    /// Pictures touching a range of stable rows, for the renderer.
    func images(intersecting rows: Range<Int>) -> [InlineImage] {
        images.filter { $0.stableRows.overlaps(rows) }
    }
}

// MARK: - Decoding

/// Reading a picture out of bytes a program sent us.
///
/// Everything goes through ImageIO. Hand-rolling a decoder for bytes that
/// arrive over a pty — including over ssh, from a machine we do not trust —
/// would be writing a new attack surface by hand when the system already
/// ships a hardened one.
enum InlineImageDecoder {

    /// Pixel dimensions of encoded bytes, without decoding the pixels.
    ///
    /// This doubles as validation: ImageIO refusing to read a header is how
    /// data that is not an image at all gets rejected before anything stores
    /// it or tries to draw it.
    static func pixelSize(ofEncoded bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard !bytes.isEmpty else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= InlineImageStore.maximumPixelSide,
              height <= InlineImageStore.maximumPixelSide
        else { return nil }
        return (width, height)
    }

    /// Decodes a picture for drawing. Nil for anything ImageIO will not read,
    /// which is the same answer `pixelSize` gives, so a picture that made it
    /// into the store will normally decode.
    static func decode(_ source: InlineImage.Source) -> CGImage? {
        switch source {
        case .encoded(let bytes):
            let options = [kCGImageSourceShouldCache: true] as CFDictionary
            guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, options) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(src, 0, options)

        case .bitmap(let rgba, let width, let height):
            guard width > 0, height > 0, rgba.count >= width * height * 4,
                  let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
            return CGImage(width: width, height: height,
                           bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue:
                                CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil,
                           shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}

// MARK: - Geometry

/// How big a picture should be, in cells.
///
/// The protocols all describe a size the same way — a number of cells, a
/// number of pixels, a percentage of the window, or "whatever the picture
/// is" — so the arithmetic lives here once rather than in each of them.
enum InlineImageGeometry {

    /// One of the sizes an inline-image protocol can ask for.
    enum Dimension: Equatable {
        case auto
        case cells(Int)
        case pixels(Int)
        case percent(Int)

        /// `N`, `Npx`, `N%` or `auto`, as iTerm2 writes them.
        init?(_ text: String) {
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            if value.isEmpty || value == "auto" { self = .auto; return }
            if value.hasSuffix("px"), let n = Int(value.dropLast(2)), n > 0 {
                self = .pixels(n); return
            }
            if value.hasSuffix("%"), let n = Int(value.dropLast()), n > 0 {
                self = .percent(min(n, 100)); return
            }
            guard let n = Int(value), n > 0 else { return nil }
            self = .cells(n)
        }

        /// The dimension in pixels, given what a cell and the window measure.
        /// Nil for `auto`, which means "ask the picture".
        func pixels(cell: CGFloat, window: CGFloat) -> CGFloat? {
            switch self {
            case .auto:              return nil
            case .cells(let n):      return CGFloat(n) * cell
            case .pixels(let n):     return CGFloat(n)
            case .percent(let n):    return window * CGFloat(n) / 100
            }
        }
    }

    /// Turns a requested size into a number of cells.
    ///
    /// Rounding is always up: a picture that needs three and a bit rows gets
    /// four, because the alternative is the last sliver of it being drawn over
    /// the next line of text.
    static func cellSpan(pixelWidth: Int, pixelHeight: Int,
                         width: Dimension, height: Dimension,
                         preserveAspectRatio: Bool,
                         cellSize: CGSize, gridCols: Int, gridRows: Int) -> (cols: Int, rows: Int) {
        let cellW = max(1, cellSize.width)
        let cellH = max(1, cellSize.height)
        let windowW = cellW * CGFloat(max(1, gridCols))
        let windowH = cellH * CGFloat(max(1, gridRows))

        let natural = CGSize(width: CGFloat(max(1, pixelWidth)),
                             height: CGFloat(max(1, pixelHeight)))
        let askedW = width.pixels(cell: cellW, window: windowW)
        let askedH = height.pixels(cell: cellH, window: windowH)

        var targetW: CGFloat
        var targetH: CGFloat
        switch (askedW, askedH) {
        case (nil, nil):
            targetW = natural.width
            targetH = natural.height
        case (let w?, nil):
            targetW = w
            targetH = w * natural.height / natural.width
        case (nil, let h?):
            targetH = h
            targetW = h * natural.width / natural.height
        case (let w?, let h?):
            if preserveAspectRatio {
                // Fit inside the box rather than filling it: the box is a
                // limit the program set, and overflowing it would draw over
                // text it expected to keep.
                let scale = min(w / natural.width, h / natural.height)
                targetW = natural.width * scale
                targetH = natural.height * scale
            } else {
                targetW = w
                targetH = h
            }
        }

        // A picture wider than the window is squeezed to fit rather than
        // clipped, so `imgcat` of a desktop screenshot shows the whole thing.
        if targetW > windowW {
            let scale = windowW / targetW
            targetW = windowW
            if preserveAspectRatio { targetH *= scale }
        }

        let cols = min(max(1, Int((targetW / cellW).rounded(.up))), max(1, gridCols))
        // Deliberately not clamped to the window height: a tall picture
        // scrolls, exactly as tall output does.
        let rows = max(1, Int((targetH / cellH).rounded(.up)))
        return (cols, rows)
    }
}
