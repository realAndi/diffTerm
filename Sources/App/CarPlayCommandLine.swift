import CarPlay

/// Typing from the car, within what CarPlay allows.
///
/// A navigation app draws its own screen but is given no touches on it, so
/// the only keyboard a car will show belongs to the search template: a text
/// field with a list of results under it. That list is the command line —
/// what has been typed runs as it stands, and this session's matching history
/// is offered beneath it, which is the difference between typing `make` and
/// typing a path at a traffic light.
///
/// The phone is still the real keyboard. There are no control keys here
/// beyond stopping a command, nothing interactive, and many cars refuse the
/// keyboard outright while the car is moving — `CarPlaySceneDelegate` hides
/// the button when the car says so.
final class CarPlayCommandLine: NSObject, CPSearchTemplateDelegate {

    private weak var interfaceController: CPInterfaceController?

    /// The last text the car reported. The keyboard's own go button arrives
    /// with no text of its own, so this is what it runs.
    private var currentText = ""

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        super.init()
    }

    /// Opens the car's keyboard over the terminal.
    func present() {
        let template = CPSearchTemplate()
        template.delegate = self
        currentText = ""
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// The session the car is showing, which is the one it types into.
    private var session: TerminalSession? {
        RootViewController.shared.activeTab?.activePane.session
    }

    /// What to offer under the field: matches for what is being typed, and
    /// with an empty field the last few commands, which is the whole reason
    /// this is usable in a car at all.
    private func history(for text: String) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard let session else { return [] }
        guard !typed.isEmpty else { return CommandHistoryStore.shared.allCommands(limit: 6) }
        return CommandHistoryStore.shared.recent(matching: typed,
                                                 pwd: session.workingDirectory, limit: 6)
    }

    private func rows(for text: String) -> [CPListItem] {
        return CarPlayCommandRows.rows(for: text, history: history(for: text)).map { row in
            let item = CPListItem(text: row.title, detailText: row.detail)
            // The row carries exactly what it will write to the shell.
            item.userInfo = row.sends
            return item
        }
    }

    private func send(_ payload: String) {
        session?.send(text: payload)
        // Back to the terminal, which is the point of doing this from a car.
        interfaceController?.popToRootTemplate(animated: true, completion: nil)
    }

    // MARK: - CPSearchTemplateDelegate

    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        currentText = searchText
        completionHandler(rows(for: searchText))
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        if let payload = item.userInfo as? String { send(payload) }
        completionHandler()
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        let typed = currentText.trimmingCharacters(in: .whitespaces)
        guard let row = CarPlayCommandRows.rows(for: typed, history: []).first,
              !typed.isEmpty else { return }
        send(row.sends)
    }
}
