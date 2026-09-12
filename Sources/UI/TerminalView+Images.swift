import UIKit

/// Drawing the pictures a program placed in the grid.
///
/// The rows an image covers are ordinary blank rows, so nothing here has to
/// coordinate with the text pass: a cell with the default background paints
/// nothing, and a blank cell draws no glyph. The picture goes down after the
/// block chrome and before the text, which leaves selection highlighting and
/// anything printed over an image visible on top of it rather than hidden
/// underneath.
extension TerminalView {

    func drawInlineImages(_ ctx: CGContext, emulator: Emulator,
                          layout: BlockLayout, rows: ClosedRange<Int>, clip: CGRect) {
        // A full-screen program owns every cell it draws; a picture anchored
        // in the normal buffer's scrollback has nothing to do with what is on
        // screen now.
        guard !emulator.modes.altScreen else { return }
        guard !emulator.images.isEmpty else {
            imageCache.removeAll(keepingCapacity: false)
            return
        }

        // Sweep first: an id the store no longer knows about is a picture that
        // was erased, and holding its bitmap would turn the store's memory
        // budget into a lie.
        let live = Set(emulator.images.images.map(\.id))
        if imageCache.count > live.count {
            imageCache = imageCache.filter { live.contains($0.key) }
        }

        let evicted = emulator.normal.scrollbackEvicted
        let visible = (rows.lowerBound + evicted)..<(rows.upperBound + evicted + 1)
        let cellW = cellSize.width
        let cellH = cellSize.height
        let gutterX = gutterWidth

        for image in emulator.images.images(intersecting: visible) {
            guard let topRow = emulator.absoluteRow(for: image.stableRow) else { continue }

            let decoded: CGImage?
            if let hit = imageCache[image.id] {
                decoded = hit
            } else {
                // Decoding is the expensive half and the bytes never change
                // once placed, so it happens once per picture rather than once
                // per frame — a scroll past an image would otherwise re-decode
                // it sixty times a second.
                decoded = InlineImageDecoder.decode(image.source)
                if let decoded { imageCache[image.id] = decoded }
            }
            guard let cg = decoded else { continue }

            // The box the picture was given, in laid-out coordinates. Its
            // height comes from the layout rather than `rows * cellH`, so a
            // picture inside a command block moves with the gaps the block
            // adds instead of drifting out of it.
            let top = layout.y(forRow: topRow) - scrollOffset
            let bottom = layout.y(forRow: topRow + image.rows) - scrollOffset
            let box = CGRect(x: gutterX + CGFloat(image.col) * cellW,
                             y: top,
                             width: CGFloat(image.cols) * cellW,
                             height: max(cellH, bottom - top))
            guard box.intersects(clip) else { continue }

            // Fit inside the box. The cell span was rounded up to whole cells,
            // so the box is a little larger than the picture asked for, and
            // stretching to fill it would distort every image by a few per
            // cent. Top-left, which is where the text it interrupts starts.
            let scale = min(box.width / CGFloat(max(1, image.pixelWidth)),
                            box.height / CGFloat(max(1, image.pixelHeight)))
            let drawn = CGRect(x: box.minX, y: box.minY,
                               width: CGFloat(image.pixelWidth) * scale,
                               height: CGFloat(image.pixelHeight) * scale)

            ctx.saveGState()
            ctx.clip(to: box.intersection(clip))
            // A CGImage's origin is bottom-left and this context is flipped
            // for UIKit, so without the flip every picture draws upside down.
            ctx.translateBy(x: drawn.minX, y: drawn.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
            ctx.restoreGState()
        }
    }
}
