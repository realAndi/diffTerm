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
        if !Preferences.shared.snippetsSeeded {
            if snippets.isEmpty { seedDefaults() }
            // Existing lists count too; an emptied list must stay empty.
            Preferences.shared.snippetsSeeded = true
        }
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

    private func presentEditor(for index: Int?, draft: Snippet? = nil) {
        let existing = draft ?? index.map { snippets[$0] }
        let alert = UIAlertController(
            title: index == nil ? "New Snippet" : "Edit Snippet",
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

        let runsImmediately = existing?.runsImmediately ?? true
        alert.addAction(UIAlertAction(title: runsImmediately ? "Press Return: On" : "Press Return: Off",
                                      style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            // Keep toggles in the draft so Cancel leaves the saved list alone.
            let draft = Snippet(title: alert.textFields?[0].text ?? "",
                                command: alert.textFields?[1].text ?? "",
                                runsImmediately: !runsImmediately)
            self.presentEditor(for: index, draft: draft)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
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
}
