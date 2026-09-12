import Foundation

extension Emulator {

    // MARK: - OSC 1337 File= (iTerm2 inline images)

    /// `OSC 1337 ; File = key=value ; … : <base64> ST`
    ///
    /// iTerm2's protocol, and what `imgcat` speaks. The keys are optional and
    /// unordered; the payload is everything after the first colon, which is
    /// safe to split on because base64 has no colon in its alphabet and
    /// neither does any key iTerm2 defines.
    ///
    /// Anything that is not a picture is dropped without a sound. A terminal
    /// that printed an error for every OSC 1337 it did not understand would be
    /// unusable next to iTerm2's other uses of the same command — setting a
    /// badge, reporting the shell's identity — none of which are ours.
    func handleITermFile(_ arg: String) {
        guard arg.hasPrefix("File=") else { return }
        let body = arg.dropFirst("File=".count)

        guard let colon = body.firstIndex(of: ":") else { return }
        let keys = body[body.startIndex..<colon]
        let encoded = body[body.index(after: colon)...]

        var width = InlineImageGeometry.Dimension.auto
        var height = InlineImageGeometry.Dimension.auto
        var preserveAspectRatio = true
        var isInline = false

        for pair in keys.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[pair.startIndex..<equals].lowercased()
            let value = String(pair[pair.index(after: equals)...])
            switch key {
            case "width":  width = InlineImageGeometry.Dimension(value) ?? .auto
            case "height": height = InlineImageGeometry.Dimension(value) ?? .auto
            case "preserveaspectratio": preserveAspectRatio = value != "0"
            case "inline": isInline = value != "0"
            default: break
            }
        }

        // `inline=0` means "download this", which a phone terminal has nowhere
        // to put. Showing it instead would be inventing a behaviour the
        // program did not ask for.
        guard isInline else { return }

        // Whitespace inside the payload is common once a long base64 string
        // has been wrapped, and Foundation refuses it without being told.
        guard let data = Data(base64Encoded: String(encoded),
                              options: .ignoreUnknownCharacters),
              !data.isEmpty else { return }

        place(encoded: [UInt8](data), width: width, height: height,
              preserveAspectRatio: preserveAspectRatio)
    }

    /// Puts an encoded picture at the cursor, if it is one.
    private func place(encoded bytes: [UInt8],
                       width: InlineImageGeometry.Dimension,
                       height: InlineImageGeometry.Dimension,
                       preserveAspectRatio: Bool) {
        guard bytes.count <= InlineImageStore.maximumImageBytes,
              let size = InlineImageDecoder.pixelSize(ofEncoded: bytes) else { return }

        let span = InlineImageGeometry.cellSpan(
            pixelWidth: size.width, pixelHeight: size.height,
            width: width, height: height,
            preserveAspectRatio: preserveAspectRatio,
            cellSize: cellSize, gridCols: cols, gridRows: rows)

        placeImage(cols: span.cols, rows: span.rows,
                   pixelWidth: size.width, pixelHeight: size.height,
                   source: .encoded(bytes))
    }

    /// Reserves the rows a picture covers and records it against them.
    ///
    /// The line feeds are the point. Feeding real blank lines is what makes an
    /// image scroll with its output, survive eviction, and leave selection,
    /// search and `BlockLayout` untouched: they all keep working on rows that
    /// exist, and the picture is chrome drawn over them. Reserving nothing and
    /// drawing over live text would put the picture on top of whatever was
    /// printed next.
    func placeImage(cols spanCols: Int, rows spanRows: Int,
                    pixelWidth: Int, pixelHeight: Int,
                    source: InlineImage.Source) {
        // The alternate screen has no scrollback to anchor to, and a
        // full-screen program redraws every cell it owns — a picture left
        // floating over vim would never be cleaned up.
        guard !modes.altScreen else { return }

        let startRow = stableCursorRow
        let startCol = buffer.cursorX

        // One feed per row: the first lands the cursor on the picture's second
        // row, the last leaves it on the line below the picture, at column
        // zero, which is where a program expects to carry on printing.
        for _ in 0..<spanRows { feedLineForImage() }

        images.insert(stableRow: startRow, col: startCol,
                      cols: spanCols, rows: spanRows,
                      pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                      source: source)
        markAll()
    }

    // MARK: - Sixel

    /// A decoded Sixel goes into the grid the same way an iTerm2 picture does.
    ///
    /// Sixel has no notion of a requested size — the payload names its own
    /// pixel dimensions and nothing else — so the cell span is always the
    /// natural one, squeezed to the window if it is wider.
    func placeSixel(_ payload: [UInt8]) {
        guard let bitmap = SixelDecoder.decode(payload) else { return }
        let span = InlineImageGeometry.cellSpan(
            pixelWidth: bitmap.width, pixelHeight: bitmap.height,
            width: .auto, height: .auto,
            preserveAspectRatio: true,
            cellSize: cellSize, gridCols: cols, gridRows: rows)
        placeImage(cols: span.cols, rows: span.rows,
                   pixelWidth: bitmap.width, pixelHeight: bitmap.height,
                   source: .bitmap(rgba: bitmap.rgba, width: bitmap.width, height: bitmap.height))
    }

    // MARK: - Erasing

    /// Pictures drawn on rows that are being cleared go with them. Without
    /// this, `clear` would leave every image on screen floating over a fresh
    /// prompt.
    func discardImages(visibleRowsOf buffer: Buffer) {
        let first = normal.scrollbackEvicted + normal.scrollbackCount
        images.discard(rows: first..<(first + buffer.rows))
    }
}
