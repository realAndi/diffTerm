import UIKit

extension TerminalPaneController: TerminalSearchBarDelegate {

    func searchBar(_ bar: TerminalSearchBar, didChangeQuery query: String) {
        recomputeMatches(for: query)
        if !searchMatches.isEmpty {
            searchIndex = closestMatchIndex()
            revealCurrentMatch()
        } else {
            searchIndex = nil
            clearSelection()
        }
        bar.update(matchIndex: searchIndex, total: searchMatches.count)
    }

    func searchBarDidTapNext(_ bar: TerminalSearchBar) {
        guard !searchMatches.isEmpty else { return }
        // Search runs newest-first, which is what someone scrolling back for a
        // recent error expects "next" to mean.
        searchIndex = ((searchIndex ?? -1) + 1) % searchMatches.count
        revealCurrentMatch()
        bar.update(matchIndex: searchIndex, total: searchMatches.count)
    }

    func searchBarDidTapPrevious(_ bar: TerminalSearchBar) {
        guard !searchMatches.isEmpty else { return }
        let current = searchIndex ?? 0
        searchIndex = (current - 1 + searchMatches.count) % searchMatches.count
        revealCurrentMatch()
        bar.update(matchIndex: searchIndex, total: searchMatches.count)
    }

    func searchBarDidDismiss(_ bar: TerminalSearchBar) {
        searchMatches = []
        searchIndex = nil
        clearSelection()
        becomeFirstResponderIfPossible()
    }

    // MARK: - Matching

    private func recomputeMatches(for query: String) {
        searchMatches = []
        let needle = query.lowercased()
        guard needle.count >= 1 else { return }

        let buffer = session.emulator.buffer
        let totalRows = buffer.totalRows
        guard totalRows > 0 else { return }

        // Walk from the newest line backwards and stop once we have plenty:
        // scanning a 200,000-line scrollback for every keystroke would stall
        // the UI, and nobody pages through more matches than this.
        let maxMatches = 500
        var row = totalRows - 1
        while row >= 0, searchMatches.count < maxMatches {
            let line = buffer.row(at: row)
            let text = line.text(to: line.trimmedLength).lowercased()
            if !text.isEmpty {
                var searchStart = text.startIndex
                while let found = text.range(of: needle, range: searchStart..<text.endIndex) {
                    let startCol = text.distance(from: text.startIndex, to: found.lowerBound)
                    let endCol = text.distance(from: text.startIndex, to: found.upperBound)
                    searchMatches.append(TerminalSelection(
                        anchor: GridPosition(row: row, col: startCol),
                        head: GridPosition(row: row, col: endCol)))
                    searchStart = found.upperBound
                    if searchMatches.count >= maxMatches { break }
                }
            }
            row -= 1
        }
    }

    private func closestMatchIndex() -> Int? {
        guard !searchMatches.isEmpty else { return nil }
        // Prefer the first match at or above the current viewport.
        let firstVisibleRow = terminalView.layout.row(atY: terminalView.scrollOffset)
        for (i, match) in searchMatches.enumerated() where match.start.row <= firstVisibleRow {
            return i
        }
        return 0
    }

    private func revealCurrentMatch() {
        guard let index = searchIndex, index < searchMatches.count else { return }
        let match = searchMatches[index]
        terminalView.selection = match

        let cellH = terminalView.cellSize.height
        let targetY = terminalView.layout.y(forRow: match.start.row) - scrollViewHeight / 2 + cellH / 2
        scrollTo(offsetY: targetY)
    }
}
