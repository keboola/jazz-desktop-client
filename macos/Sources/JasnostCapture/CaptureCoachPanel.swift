import AppKit
import JasnostCaptureCore

/// Small floating advisory surface. `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded`, and ordinary
/// `orderFront` preserve the demonstrated application's activation and key-window state; the panel
/// becomes key only after the user explicitly clicks into the answer field.
@MainActor
final class CaptureCoachPanel: NSObject {
    var onAnswer: ((String) -> Void)?
    var onSpokenAnswer: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onMute: (() -> Void)?
    var onResume: (() -> Void)?
    var onFinishAnyway: (() -> Void)?

    private var panel: NSPanel!
    private let question = NSTextField(wrappingLabelWithString: "")
    private let answer = NSTextField(string: "")
    private let answerButton = NSButton(title: "Answer", target: nil, action: nil)
    private let spokenAnswerButton = NSButton(title: "Answer aloud", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private let muteButton = NSButton(title: "Mute 5 min", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish anyway", target: nil, action: nil)

    override init() {
        super.init()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 190),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "Capture Coach"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        question.maximumNumberOfLines = 3
        question.lineBreakMode = .byWordWrapping
        answer.placeholderString = "Type what is important about this step…"
        answer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configure(answerButton, action: #selector(answerPressed))
        configure(spokenAnswerButton, action: #selector(spokenAnswerPressed))
        configure(dismissButton, action: #selector(dismissPressed))
        configure(muteButton, action: #selector(mutePressed))
        configure(resumeButton, action: #selector(resumePressed))
        configure(finishButton, action: #selector(finishPressed))

        let actions = NSStackView(views: [
            answerButton, spokenAnswerButton, dismissButton, muteButton, resumeButton, finishButton,
        ])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        let stack = NSStackView(views: [question, answer, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        answer.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            answer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = content
    }

    func show(prompt: CaptureCoachPrompt, spokenAvailable: Bool) {
        question.stringValue = prompt.snapshot.text
        answer.stringValue = ""
        answer.isHidden = false
        answerButton.isHidden = false
        spokenAnswerButton.isHidden = !prompt.snapshot.responseModes.contains(.spoken)
        spokenAnswerButton.isEnabled = spokenAvailable
        spokenAnswerButton.toolTip =
            spokenAvailable
            ? "Use the audio currently recording inside this open label"
            : "Open a label with an actively recording microphone first"
        dismissButton.isHidden = false
        muteButton.isHidden = false
        resumeButton.isHidden = true
        finishButton.isHidden = false
        presentWithoutActivating()
    }

    func showMuted(until: String) {
        question.stringValue = "Capture Coach is muted until \(until). Capture continues normally."
        answer.isHidden = true
        answerButton.isHidden = true
        spokenAnswerButton.isHidden = true
        dismissButton.isHidden = true
        muteButton.isHidden = true
        resumeButton.isHidden = false
        finishButton.isHidden = false
        presentWithoutActivating()
    }

    func hide() { panel.orderOut(nil) }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    private func presentWithoutActivating() {
        if let frame = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: frame.maxX - panel.frame.width - 20,
                y: frame.maxY - panel.frame.height - 20)
            panel.setFrameOrigin(origin)
        }
        panel.orderFront(nil)
    }

    @objc private func answerPressed() {
        let value = answer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onAnswer?(value)
        hide()
    }

    @objc private func dismissPressed() {
        onDismiss?()
        hide()
    }

    @objc private func spokenAnswerPressed() {
        guard spokenAnswerButton.isEnabled else { return }
        onSpokenAnswer?()
        hide()
    }

    @objc private func mutePressed() { onMute?() }
    @objc private func resumePressed() { onResume?() }

    @objc private func finishPressed() {
        onFinishAnyway?()
        hide()
    }
}
