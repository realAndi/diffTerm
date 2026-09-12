import UIKit

/// A declarative description of one settings row. Building the screen from a
/// model keeps the table view's data source boring and makes it obvious what
/// the app can actually be configured to do.
enum SettingsRow {
    case toggle(title: String, subtitle: String? = nil,
                get: () -> Bool, set: (Bool) -> Void)
    case choice(title: String, value: () -> String, pick: (UIViewController) -> Void)
    case stepper(title: String, value: () -> String,
                 decrement: () -> Void, increment: () -> Void,
                 canDecrement: () -> Bool, canIncrement: () -> Bool)
    case text(title: String, placeholder: String,
              get: () -> String, set: (String) -> Void)
    case disclosure(title: String, detail: String? = nil, action: (UIViewController) -> Void)
    case button(title: String, destructive: Bool, action: (UIViewController) -> Void)
    case info(title: String, detail: String)

    var title: String {
        switch self {
        case .toggle(let t, _, _, _),
             .choice(let t, _, _),
             .stepper(let t, _, _, _, _, _),
             .text(let t, _, _, _),
             .disclosure(let t, _, _),
             .button(let t, _, _),
             .info(let t, _):
            return t
        }
    }
}

struct SettingsSection {
    var header: String?
    var footer: String?
    var rows: [SettingsRow]
}

/// Cell with an inline text field, used for paths and commands.
final class TextFieldCell: UITableViewCell, UITextFieldDelegate {

    let field = UITextField()
    var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.textAlignment = .right
        field.delegate = self
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(field)

        guard let label = textLabel else { return }
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func editingChanged() {
        onChange?(field.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

/// Cell with a minus/plus pair, used for font size and line height.
final class StepperCell: UITableViewCell {

    private let valueLabel = UILabel()
    private let minusButton = UIButton(type: .system)
    private let plusButton = UIButton(type: .system)

    var onDecrement: (() -> Void)?
    var onIncrement: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right

        minusButton.setImage(UIImage(systemName: "minus"), for: .normal)
        plusButton.setImage(UIImage(systemName: "plus"), for: .normal)
        minusButton.addTarget(self, action: #selector(decrement), for: .touchUpInside)
        plusButton.addTarget(self, action: #selector(increment), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [valueLabel, minusButton, plusButton])
        stack.axis = .horizontal
        stack.spacing = 14
        stack.alignment = .center
        accessoryView = stack
        stack.frame = CGRect(x: 0, y: 0, width: 130, height: 32)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(value: String, canDecrement: Bool, canIncrement: Bool) {
        valueLabel.text = value
        minusButton.isEnabled = canDecrement
        plusButton.isEnabled = canIncrement
    }

    @objc private func decrement() { onDecrement?() }
    @objc private func increment() { onIncrement?() }
}

/// A plain list picker, pushed for anything with more than a couple of
/// options. Optionally renders a preview swatch alongside each row.
final class ListPickerController: UITableViewController {

    struct Option {
        var title: String
        var subtitle: String?
        var swatch: [UIColor]?
        var isSelected: Bool
        var select: () -> Void
    }

    private let options: [Option]
    private let onPick: () -> Void

    init(title: String, options: [Option], onPick: @escaping () -> Void) {
        self.options = options
        self.onPick = onPick
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let option = options[indexPath.row]
        let cell = UITableViewCell(style: option.subtitle == nil ? .default : .subtitle,
                                   reuseIdentifier: nil)
        cell.textLabel?.text = option.title
        cell.detailTextLabel?.text = option.subtitle
        cell.accessoryType = option.isSelected ? .checkmark : .none
        if let swatch = option.swatch {
            cell.accessoryView = option.isSelected ? nil : SwatchView(colors: swatch)
            if option.isSelected {
                cell.accessoryType = .checkmark
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        options[indexPath.row].select()
        onPick()
        navigationController?.popViewController(animated: true)
    }
}

/// A row of colour chips previewing a theme.
final class SwatchView: UIView {
    init(colors: [UIColor]) {
        super.init(frame: CGRect(x: 0, y: 0, width: CGFloat(colors.count) * 14 + 6, height: 18))
        layer.cornerRadius = 4
        clipsToBounds = true
        for (i, color) in colors.enumerated() {
            let chip = UIView(frame: CGRect(x: CGFloat(i) * 14, y: 0, width: 14, height: 18))
            chip.backgroundColor = color
            addSubview(chip)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
