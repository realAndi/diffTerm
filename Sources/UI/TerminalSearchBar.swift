import UIKit

protocol TerminalSearchBarDelegate: AnyObject {
    func searchBar(_ bar: TerminalSearchBar, didChangeQuery query: String)
    func searchBarDidTapNext(_ bar: TerminalSearchBar)
    func searchBarDidTapPrevious(_ bar: TerminalSearchBar)
    func searchBarDidDismiss(_ bar: TerminalSearchBar)
}

/// Find-in-scrollback bar, pinned under the safe area at the top of a pane.
final class TerminalSearchBar: UIView {

    weak var delegate: TerminalSearchBarDelegate?

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let field = UITextField()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUp() {
        background.frame = bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(background)

        field.placeholder = "Find in terminal"
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.font = .systemFont(ofSize: 15)
        field.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(returnTapped), for: .editingDidEndOnExit)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabel
        countLabel.textAlignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        configure(previousButton, symbol: "chevron.up", action: #selector(previousTapped))
        configure(nextButton, symbol: "chevron.down", action: #selector(nextTapped))
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [field, countLabel, previousButton, nextButton, doneButton])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func configure(_ button: UIButton, symbol: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.isEnabled = false
    }

    var query: String { field.text ?? "" }

    func beginEditing() {
        field.becomeFirstResponder()
    }

    func update(matchIndex: Int?, total: Int) {
        if total == 0 {
            countLabel.text = query.isEmpty ? "" : "None"
        } else if let matchIndex {
            countLabel.text = "\(matchIndex + 1)/\(total)"
        } else {
            countLabel.text = "\(total)"
        }
        previousButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
    }

    @objc private func queryChanged() { delegate?.searchBar(self, didChangeQuery: query) }
    @objc private func returnTapped() { delegate?.searchBarDidTapNext(self) }
    @objc private func nextTapped() { delegate?.searchBarDidTapNext(self) }
    @objc private func previousTapped() { delegate?.searchBarDidTapPrevious(self) }

    @objc private func doneTapped() {
        field.resignFirstResponder()
        field.text = ""
        update(matchIndex: nil, total: 0)
        isHidden = true
        delegate?.searchBarDidDismiss(self)
    }
}

/// A scroll view that stands down while a program is tracking the pointer, so
/// that dragging inside e.g. a tmux pane reaches the program instead of
/// scrolling the scrollback out from under it.
final class ScrollCapturingScrollView: UIScrollView {

    var shouldCaptureTouches: () -> Bool = { true }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer, !shouldCaptureTouches() { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}
