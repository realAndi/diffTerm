import UIKit

/// Renders a `[SettingsSection]`. Both the settings screen and the key row
/// editor are the same table with a different model, and a settings screen
/// that looks like the settings screen is worth more than the fifty lines it
/// costs to share.
class SettingsTableViewController: UITableViewController {

    var sections: [SettingsSection] = []

    init(title: String) {
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(TextFieldCell.self, forCellReuseIdentifier: "text")
        tableView.register(StepperCell.self, forCellReuseIdentifier: "stepper")
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    /// Subclasses describe their screen here. Anything that changes a value
    /// calls `rebuild()`, so the rows always show what is actually stored.
    func buildSections() -> [SettingsSection] { [] }

    func rebuild() {
        sections = buildSections()
        tableView.reloadData()
    }

    // MARK: - Table view

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]

        switch row {
        case .toggle(let title, let subtitle, let get, let set):
            let cell = UITableViewCell(style: subtitle == nil ? .default : .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = subtitle
            cell.detailTextLabel?.numberOfLines = 0
            cell.selectionStyle = .none
            let toggle = UISwitch()
            toggle.isOn = get()
            toggle.addAction(UIAction { [weak self] action in
                guard let sw = action.sender as? UISwitch else { return }
                set(sw.isOn)
                self?.rebuild()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            return cell

        case .choice(let title, let value, _):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = value()
            cell.accessoryType = .disclosureIndicator
            return cell

        case .stepper(let title, let value, let dec, let inc, let canDec, let canInc):
            let cell = tableView.dequeueReusableCell(withIdentifier: "stepper", for: indexPath) as! StepperCell
            cell.textLabel?.text = title
            cell.configure(value: value(), canDecrement: canDec(), canIncrement: canInc())
            cell.onDecrement = { [weak self] in dec(); self?.rebuild() }
            cell.onIncrement = { [weak self] in inc(); self?.rebuild() }
            return cell

        case .text(let title, let placeholder, let get, let set):
            let cell = tableView.dequeueReusableCell(withIdentifier: "text", for: indexPath) as! TextFieldCell
            cell.textLabel?.text = title
            cell.field.placeholder = placeholder
            cell.field.text = get()
            cell.onChange = set
            return cell

        case .disclosure(let title, let detail, _):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = detail
            cell.accessoryType = .disclosureIndicator
            return cell

        case .button(let title, let destructive, _):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = title
            cell.textLabel?.textColor = destructive ? .systemRed : .accentCompat
            cell.textLabel?.textAlignment = .center
            return cell

        case .info(let title, let detail):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = detail
            cell.selectionStyle = .none
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .choice(_, _, let pick):        pick(self)
        case .disclosure(_, _, let action):  action(self)
        case .button(_, _, let action):      action(self)
        default: break
        }
    }
}
