import UIKit

/// Which keys the row carries, and any combinations someone has added to it.
///
/// The row scrolls, so the cost of a key you never press is the arrows being
/// further away — which is the whole reason this screen exists. Turning things
/// off is as much the point as adding them.
final class KeyRowSettingsViewController: SettingsTableViewController {

    private let prefs = Preferences.shared

    init() {
        super.init(title: "Key Row")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addCustomKey))
    }

    override func buildSections() -> [SettingsSection] {
        [builtInSection(), customSection()]
    }

    private func builtInSection() -> SettingsSection {
        let rows: [SettingsRow] = KeyRowView.toggleableKeys.map { key in
            .toggle(title: key.name,
                    get: { !self.prefs.hiddenKeyRowKeys.contains(key.id) },
                    set: { shown in
                        var hidden = self.prefs.hiddenKeyRowKeys
                        if shown { hidden.remove(key.id) } else { hidden.insert(key.id) }
                        self.prefs.hiddenKeyRowKeys = hidden
                    })
        }
        return SettingsSection(header: "Keys",
                               footer: "The row scrolls, so every key you leave on is one more "
                                     + "between your thumb and the arrows.",
                               rows: rows)
    }

    private func customSection() -> SettingsSection {
        var rows: [SettingsRow] = prefs.customKeys.enumerated().map { index, key in
            .disclosure(title: key.title, detail: key.summary, action: { [weak self] _ in
                self?.editCustomKey(at: index)
            })
        }
        rows.append(.button(title: "Add Combination", destructive: false, action: { [weak self] _ in
            self?.addCustomKey()
        }))
        if !prefs.customKeys.isEmpty {
            rows.append(.button(title: "Remove All", destructive: true, action: { [weak self] host in
                let alert = UIAlertController(title: "Remove all custom keys?",
                                              message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
                    self?.prefs.customKeys = []
                    self?.rebuild()
                })
                host.present(alert, animated: true)
            }))
        }
        return SettingsSection(
            header: "Custom Combinations",
            footer: "One press sends the whole combination. ctrl+c, alt+., shift+tab.",
            rows: rows)
    }

    // MARK: - Editing

    @objc private func addCustomKey() {
        present(editor(for: nil), animated: true)
    }

    private func editCustomKey(at index: Int) {
        present(editor(for: index), animated: true)
    }

    /// Deliberately an alert rather than a form screen, matching Snippets: a
    /// label, the modifiers spelled the way people already write them, and the
    /// key they land on.
    private func editor(for index: Int?) -> UIAlertController {
        let existing = index.map { prefs.customKeys[$0] }

        let alert = UIAlertController(
            title: existing == nil ? "New Combination" : "Edit Combination",
            message: "Modifiers: any of ctrl, alt, shift, separated by spaces or plus signs.\n"
                   + "Key: a single character, or one of "
                   + "esc tab up down left right home end pageUp pageDown insert delete f1–f12.",
            preferredStyle: .alert)

        alert.addTextField { field in
            field.placeholder = "Label, e.g. ^C"
            field.text = existing?.title
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Modifiers, e.g. ctrl"
            field.text = existing.map { CustomKey.encode($0.modifiers).replacingOccurrences(of: ",", with: " ") }
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Key, e.g. c"
            field.text = existing.map { $0.special?.rawValue ?? $0.character }
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let index {
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                guard let self else { return }
                var keys = self.prefs.customKeys
                keys.remove(at: index)
                self.prefs.customKeys = keys
                self.rebuild()
            })
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let fields = alert.textFields ?? []
            let label = (fields.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            let modifierText = fields.count > 1 ? (fields[1].text ?? "") : ""
            let keyText = (fields.count > 2 ? (fields[2].text ?? "") : "")
                .trimmingCharacters(in: .whitespaces)

            guard let key = Self.makeKey(label: label, modifiers: modifierText, key: keyText) else {
                self.presentInvalid()
                return
            }
            var keys = self.prefs.customKeys
            if let index { keys[index] = key } else { keys.append(key) }
            self.prefs.customKeys = keys
            self.rebuild()
        })
        return alert
    }

    /// Parsing is forgiving about how the modifiers are written — "ctrl+alt",
    /// "ctrl alt", "Control, Alt" all mean the same thing — and strict about
    /// the key, because a combination that sends nothing is just a dead button.
    static func makeKey(label: String, modifiers: String, key: String) -> CustomKey? {
        var flags: KeyModifiers = []
        let words = modifiers.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: " +,"))
            .filter { !$0.isEmpty }
        for word in words {
            switch word {
            case "ctrl", "control", "^":     flags.insert(.control)
            case "alt", "opt", "option", "meta": flags.insert(.alt)
            case "shift":                    flags.insert(.shift)
            default: return nil
            }
        }

        guard !key.isEmpty else { return nil }
        let special = SpecialKeyID(rawValue: key) ?? SpecialKeyID(rawValue: key.lowercased())
        if special == nil && key.count != 1 { return nil }

        let title = label.isEmpty
            ? (special.map { $0.rawValue } ?? key)
            : label
        return CustomKey(title: title, modifiers: flags,
                         special: special, character: special == nil ? key : "")
    }

    private func presentInvalid() {
        let alert = UIAlertController(
            title: "Not a key combination",
            message: "Modifiers must be ctrl, alt or shift. The key must be one character or a "
                   + "named key such as tab or f5.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
