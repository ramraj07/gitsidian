import AppIntents
import WidgetKit

/// `checkbox(...)` / `checklist(...)`: tick a markdown task line from the Home Screen. The tap is
/// shown at once, queued, and committed straight to GitHub from the widget extension; no app launch.
struct ToggleTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick a widget task"
    static var isDiscoverable = false

    @Parameter(title: "Widget") var widgetID: String
    @Parameter(title: "File") var path: String
    @Parameter(title: "Task") var text: String
    @Parameter(title: "Checked") var checked: Bool

    init() {}
    init(widgetID: String, box: CheckboxNode) {
        self.widgetID = widgetID
        self.path = box.path
        self.text = box.text
        self.checked = !box.checked
    }

    func perform() async throws -> some IntentResult {
        let store = WidgetStore.shared
        let toggle = TaskToggle(widgetID: widgetID, path: path, text: text, checked: checked)
        store.setOverride(TaskOverride(checked: checked, widgetSha: store.record(id: widgetID)?.baseSha), for: toggle.key)
        store.enqueue(toggle)
        await TaskSync.flush()
        // The tap (and, for tasks in the widget file, the new file) is already in the store.
        store.markSkipFetchOnce(widgetID)
        WidgetCenter.shared.reloadTimelines(ofKind: GitsidianWidget.kind)
        return .result()
    }
}

/// Sends queued taps to GitHub. Taps made offline stay queued and are retried on the next tap
/// or timeline refresh.
enum TaskSync {
    static func flush() async {
        let store = WidgetStore.shared
        guard let token = Keychain.read() else { return }
        for toggle in store.pendingToggles() {
            guard let record = store.record(id: toggle.widgetID) else {
                drop(toggle)   // the widget file is gone from every vault
                continue
            }
            do {
                try await commit(toggle, record: record, token: token)
                drop(toggle, keepOverride: true)
            } catch TaskError.taskNotFound, TaskError.fileMissing {
                // The line was edited or deleted elsewhere: let the script's value show again.
                drop(toggle)
            } catch {
                return   // offline, rate-limited or signed out: keep the queue in order and retry later
            }
        }
    }

    enum TaskError: Error { case fileMissing, taskNotFound }

    private static func commit(_ t: TaskToggle, record: WidgetRecord, token: String, attempt: Int = 0) async throws {
        guard case .found(let sha, let text) = try await RemoteFile.fetch(owner: record.owner, repo: record.repo,
                                                                          branch: record.branch, path: t.path, token: token) else {
            throw TaskError.fileMissing
        }
        let newText: String
        let newSha: String
        switch TaskLines.set(t.text, checked: t.checked, in: text) {
        case .notFound:
            throw TaskError.taskNotFound
        case .unchanged:
            newText = text
            newSha = sha
        case .changed(let updated):
            let verb = t.checked ? "Check off" : "Uncheck"
            do {
                newSha = try await RemoteFile.put(owner: record.owner, repo: record.repo, branch: record.branch, path: t.path,
                                                  text: updated, sha: sha, message: "\(verb) \"\(t.text)\" from widget", token: token)
            } catch let e as RemoteFile.HTTPError where e.isConflict && attempt < 2 {
                return try await commit(t, record: record, token: token, attempt: attempt + 1)
            }
            newText = updated
        }
        // A task in the widget file itself: the file just changed, so run the new version.
        if t.path == record.path, var r = WidgetStore.shared.record(id: record.id) {
            r.script = newText
            r.baseSha = newSha
            r.updatedAt = Date()
            WidgetStore.shared.update(r)
            if WidgetStore.shared.overrides()[t.key] != nil {
                WidgetStore.shared.setOverride(TaskOverride(checked: t.checked, widgetSha: newSha), for: t.key)
            }
        }
    }

    private static func drop(_ t: TaskToggle, keepOverride: Bool = false) {
        let store = WidgetStore.shared
        store.setPendingToggles(store.pendingToggles().filter { $0 != t })
        if !keepOverride { store.setOverride(nil, for: t.key) }
    }
}
