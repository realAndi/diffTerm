import UIKit

/// Warp-style command blocks.
///
/// Each command and its output are drawn as a card: a rounded panel lifted
/// slightly off the terminal void, a status rail down its left edge, and a gap
/// of air to the next card. Collapsing a command hides its output behind a
/// one-line summary. The card is chrome *behind* the grid — default-background
/// cells let it show through, cells with their own colour paint over it — so
/// the text still renders exactly as it always did; what changed is that the
/// vertical positions now come from `BlockLayout` rather than `row *
/// cellHeight`, which is what makes the gaps and the collapse possible.
///
/// Marks come from OSC 133, so a shell that emits none produces no cards and
/// the terminal looks the way it did before.
extension TerminalView {

    private struct RailColors {
        var rail: Theme.RGB
        var wash: Theme.RGB?
    }

    private func colors(for outcome: CommandBlock.Outcome) -> RailColors {
        let bg = palette.defaultBackground
        let fg = palette.defaultForeground
        switch outcome {
        case .failed:
            let red = palette.colors.count > 1 ? palette.colors[1] : fg
            return RailColors(rail: red, wash: bg.blended(with: red, amount: 0.07))
        case .running:
            let cyan = palette.colors.count > 6 ? palette.colors[6] : fg
            return RailColors(rail: cyan, wash: bg.blended(with: cyan, amount: 0.05))
        case .succeeded:
            return RailColors(rail: palette.secondaryForeground(minimumContrast: 3.0), wash: nil)
        case .pending:
            return RailColors(rail: palette.secondaryForeground(minimumContrast: 2.2), wash: nil)
        }
    }

    /// The card's own background — a hair lifted from the terminal ground, so
    /// blocks read as panels without a heavy fill fighting the text colours.
    private var cardBackground: Theme.RGB {
        let bg = palette.defaultBackground
        return bg.blended(with: palette.defaultForeground, amount: 0.05)
    }

    private var cardBorder: Theme.RGB {
        palette.defaultBackground.blended(with: palette.defaultForeground, amount: 0.14)
    }

    /// Paints the cards for the blocks touching `rows`, before any cell.
    func drawBlocks(_ ctx: CGContext, emulator: Emulator,
                    rows: ClosedRange<Int>, clip: CGRect) {
        guard blockMode, !emulator.modes.altScreen else { return }
        let integration = emulator.shellIntegration
        guard !integration.isEmpty else { return }

        let layout = self.layout
        let evicted = emulator.oldestStableRow
        let liveEnd = emulator.stableCursorRow
        let stableRows = (rows.lowerBound + evicted)...(rows.upperBound + evicted)
        let visible = integration.blocks(overlapping: stableRows, liveEnd: liveEnd)
        guard !visible.isEmpty else { return }

        let cardInset: CGFloat = 2
        let radius: CGFloat = 7
        let railInset: CGFloat = 4
        let railWidth: CGFloat = 3
        let cardX = cardInset
        let cardWidth = bounds.width - cardInset * 2

        for block in visible {
            let stable = block.stableRows(liveEnd: liveEnd)
            let promptRow = max(0, stable.lowerBound - evicted)
            let endRow = min(emulator.buffer.totalRows, stable.upperBound - evicted + 1)
            guard endRow > promptRow else { continue }

            let top = layout.y(forRow: promptRow) - scrollOffset
            let bottom = layout.y(forRow: endRow) - scrollOffset
            guard bottom > clip.minY - 1, top < clip.maxY + 1 else { continue }

            let card = CGRect(x: cardX, y: top, width: cardWidth, height: max(0, bottom - top))
            let palette = colors(for: block.outcome)

            // Card body.
            let path = UIBezierPath(roundedRect: card, cornerRadius: radius)
            ctx.saveGState()
            ctx.addPath(path.cgPath)
            ctx.setFillColor((palette.wash ?? cardBackground).cgColor)
            ctx.fillPath()
            ctx.addPath(path.cgPath)
            ctx.setStrokeColor(cardBorder.cgColor)
            ctx.setLineWidth(1 / (window?.screen.scale ?? UIScreen.main.scale))
            ctx.strokePath()
            ctx.restoreGState()

            // Status rail, inside the left edge.
            let railRect = CGRect(x: cardX + railInset, y: top + radius,
                                  width: railWidth, height: max(0, card.height - radius * 2))
            let rail = UIBezierPath(roundedRect: railRect, cornerRadius: railWidth / 2)
            ctx.setFillColor(palette.rail.cgColor)
            ctx.addPath(rail.cgPath)
            ctx.fillPath()

            // Collapsed: the output is one summary strip. Draw its label; the
            // command line above it is a normal (visible) row and paints
            // itself.
            if let output = block.outputStart.map({ $0 - evicted }),
               collapsedBlocks.contains(block.promptStart),
               let summary = layout.summary(forRow: output) {
                drawCollapsedSummary(ctx, top: summary.top - scrollOffset,
                                     hiddenRows: summary.hiddenRows,
                                     cardX: cardX, cardWidth: cardWidth,
                                     rail: palette.rail)
            }
        }
    }

    private func drawCollapsedSummary(_ ctx: CGContext, top: CGFloat, hiddenRows: Int,
                                      cardX: CGFloat, cardWidth: CGFloat, rail: Theme.RGB) {
        let cellH = cellSize.height
        let label = "▸ \(hiddenRows) line\(hiddenRows == 1 ? "" : "s") hidden"
        let color = palette.secondaryForeground(minimumContrast: 3.0).uiColor
        let font = UIFont.monospacedSystemFont(ofSize: min(13, cellH * 0.8), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: label, attributes: attributes)
        let size = string.size()
        let point = CGPoint(x: cardX + gutterWidth,
                            y: top + (cellH - size.height) / 2)
        guard point.y + size.height > 0, point.y < bounds.height else { return }
        UIGraphicsPushContext(ctx)
        string.draw(at: point)
        UIGraphicsPopContext()
    }

    /// The block whose card was tapped in the gutter, if any.
    func blockForGutterTap(at point: CGPoint, emulator: Emulator) -> CommandBlock? {
        guard blockMode, point.x < gutterWidth, !emulator.modes.altScreen else { return nil }
        let stable = row(at: point) + emulator.oldestStableRow
        return emulator.shellIntegration.block(containing: stable)
    }
}
