import UIKit

/// Saved commands, reachable from the key row. Kept deliberately plain: a
/// title, the text to send, and whether to press return for you.
final class SnippetsViewController: UITableViewController {

    private var snippets: [Snippet] = []

    init() {
        super.init(style: .insetGrouped)
        title = "Snippets"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        snippets = Preferences.shared.snippets
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addSnippet)),
            editButtonItem,
        ]
        if snippets.isEmpty { seedDefaults() }
    }

    /// A brand new install with an empty list looks broken; these are the
    /// commands people actually reach for on a phone keyboard.
    private func seedDefaults() {
        snippets = [
            Snippet(title: "ls -la", command: "ls -la", runsImmediately: true),
            Snippet(title: "Disk usage", command: "df -h", runsImmediately: true),
            Snippet(title: "Processes", command: "ps aux | head -30", runsImmediately: true),
            Snippet(title: "sudo", command: "sudo ", runsImmediately: false),
        ]
        persist()
    }

    private func persist() {
        Preferences.shared.snippets = snippets
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        snippets.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let snippet = snippets[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = snippet.title
        cell.detailTextLabel?.text = snippet.command + (snippet.runsImmediately ? " ⏎" : "")
        cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        edit(at: indexPath.row)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { true }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView,
                            commit style: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard style == .delete else { return }
        snippets.remove(at: indexPath.row)
        persist()
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    override func tableView(_ tableView: UITableView,
                            moveRowAt source: IndexPath, to destination: IndexPath) {
        let item = snippets.remove(at: source.row)
        snippets.insert(item, at: destination.row)
        persist()
    }

    @objc private func addSnippet() {
        presentEditor(for: nil)
    }

    private func edit(at index: Int) {
        presentEditor(for: index)
    }

    private func presentEditor(for index: Int?) {
        let existing = index.map { snippets[$0] }
        let alert = UIAlertController(
            title: existing == nil ? "New Snippet" : "Edit Snippet",
            message: nil, preferredStyle: .alert)

        alert.addTextField { field in
            field.placeholder = "Name"
            field.text = existing?.title
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Command"
            field.text = existing?.command
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        }

        var runsImmediately = existing?.runsImmediately ?? true
        alert.addAction(UIAlertAction(title: runsImmediately ? "Press Return: On" : "Press Return: Off",
                                      style: .default) { [weak self] _ in
            // Toggling reopens the editor with the flag flipped, which keeps
            // this to one alert instead of a whole form screen.
            runsImmediately.toggle()
            let title = alert.textFields?[0].text ?? ""
            let command = alert.textFields?[1].text ?? ""
            self?.reopenEditor(index: index, title: title, command: command, runs: runsImmediately)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let title = (alert.textFields?[0].text ?? "").trimmingCharacters(in: .whitespaces)
            let command = alert.textFields?[1].text ?? ""
            guard !command.isEmpty else { return }
            let snippet = Snippet(title: title.isEmpty ? command : title,
                                  command: command,
                                  runsImmediately: runsImmediately)
            if let index {
                self.snippets[index] = snippet
            } else {
                self.snippets.append(snippet)
            }
            self.persist()
            self.tableView.reloadData()
        })

        present(alert, animated: true)
    }

    private func reopenEditor(index: Int?, title: String, command: String, runs: Bool) {
        let snippet = Snippet(title: title, command: command, runsImmediately: runs)
        if let index {
            snippets[index] = snippet
            persist()
            presentEditor(for: index)
        } else {
            snippets.append(snippet)
            persist()
            tableView.reloadData()
            presentEditor(for: snippets.count - 1)
        }
    }
}
