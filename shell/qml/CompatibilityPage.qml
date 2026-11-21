pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// A .play game's Compatibility page (RUY-905, 05 §6.2, 02 §1.8): which runner the game starts with, the
// signed-in profile's choice of runner (Package default, Bundled when the package has a copy, System), the
// version the developer tested, and the bundled and system runners there are. Opened from the game page's
// Compatibility row with params { id } (a Library item id). Everything comes from Library1 through the
// Library facade, which follows the signed-in profile: the stored choice (runnerChoice) and the launcher's
// own dry run for each choice (resolveRunner), asked once when the page opens; a change is stored at once
// and the preview of that choice is asked again. After a crash on the system runner, "Try the bundled
// runner" stores Bundled and starts the game. A refusal is worded by its code (RunnerText), never by
// Library1's English sentence. Back (or Left, except on the Runner row) closes the page.
Page {
    id: page

    readonly property string itemId: String((params ?? {}).id ?? "")
    readonly property var item: Library.items.find(i => i.id === page.itemId) ?? ({})
    readonly property string appId: item.id !== undefined ? Library.sessionAppId(item.id) : ""
    // The name is AppName's; an item the Library no longer lists keeps the last name seen.
    property string lastName: ""
    readonly property string shownName: AppName.of(appId)
    onShownNameChanged: if (shownName !== "") lastName = shownName
    title: lastName !== "" ? lastName : (item.title ?? "")

    // ---- The service's answers ----
    // The stored choice ("" until answered) and the status of that answer.
    property string choice: ""
    property string choiceStatus: ""
    // The choice the page opened with: a change while the game runs applies at its next start.
    property string openedChoice: ""
    // choice -> { status, resolution } of resolveRunner, one per RunnerText.choices.
    property var answers: ({})
    // The choice being stored ("" none) and the one before it, which a refused store goes back to.
    property string saving: ""
    property string savedBefore: ""
    // Try the bundled runner: start the game once Bundled is stored.
    property bool launchAfterSave: false
    property string saveError: ""

    readonly property bool failed: !Library.available || (choiceStatus !== "" && choiceStatus !== "ok")
        || RunnerText.choices.some(c => page.answers[c] !== undefined && page.answers[c].status !== "ok")
    readonly property bool loaded: !failed && choiceStatus === "ok" && RunnerText.choices.every(c => page.answers[c] !== undefined)
    readonly property bool loading: !failed && !loaded

    function resolutionOf(c) {
        return loaded && answers[c] ? answers[c].resolution : ({})
    }
    // What the launch would run with the stored choice: the preview of the Runner row.
    readonly property var preview: resolutionOf(choice)
    readonly property bool refused: (preview.playResolveError ?? "") !== "" || (preview.playResolveCode ?? "") !== ""
    // The package has a bundled copy: asking for it is answered with it, not with the package default.
    readonly property var bundledAnswer: resolutionOf("bundled")
    readonly property bool hasBundled: bundledAnswer.playRunnerSource === "bundled" && !bundledAnswer.playFallback
    // "<family> <version>" -> the family.
    function familyOf(runner) {
        return String(runner ?? "").split(" ")[0]
    }
    // The runner family the game's component uses: its bundled copy's, else the one the launch would run.
    readonly property string family: hasBundled ? familyOf(bundledAnswer.playRunner)
        : familyOf(preview.playRunner || resolutionOf("package").playRunner || resolutionOf("system").playRunner)
    // The image's runners of that family (Library1 ListRunners), "<family> <version>".
    readonly property var systemRunners: family === "" ? [] : Library.runners.filter(r => r.family === page.family)
        .map(r => r.family + " " + r.version)

    readonly property bool running: Session.running.some(r => r.appId === page.appId && r.state !== "stopping")
    // The newest session of this game for the signed-in profile ended in a crash (Session1's ledger).
    readonly property bool crashedLast: {
        const last = Usage.history.find(h => h.appId === page.appId)
        return last !== undefined && last.reason === "crashed"
    }
    onVisibleChanged: Usage.setWatching(page, visible)
    readonly property bool tryShown: loaded && crashedLast && preview.playRunnerSource === "system" && hasBundled

    readonly property var runnerOptions: RunnerText.choices
        .filter(c => c !== "bundled" || page.hasBundled || page.choice === "bundled")
        .map(c => ({ value: c, label: RunnerText.choiceWord(c) }))
    // The note under the Runner row: a choice the package can't honour, or a change that waits for the next start.
    readonly property string runnerNote: !loaded ? ""
        : preview.playFallback === true ? RunnerText.fallbackNote(choice)
        : running && openedChoice !== "" && choice !== openedChoice ? qsTr("Takes effect the next time the game starts.")
        : ""

    function load() {
        choiceStatus = ""
        answers = ({})
        saveError = ""
        Library.runnerChoice(itemId)
        for (const c of RunnerText.choices)
            Library.resolveRunner(itemId, c)
    }
    Component.onCompleted: {
        load()
        Usage.setWatching(page, visible)
    }

    function store(value) {
        if (saving !== "" || value === choice) {
            runnerRow.value = choice        // one store at a time: the row shows what is stored
            return
        }
        savedBefore = choice
        saving = value
        choice = value
        saveError = ""
        Library.setRunnerChoice(itemId, value)
    }
    function tryBundled() {
        if (saving !== "")
            return
        launchAfterSave = true
        store("bundled")
    }
    function notAvailable() {
        Sfx.back()
        Notifications.show(qsTr("Runner: the library isn't responding."), "warning")
    }

    Connections {
        target: Library
        function onRunnerChoiceAnswered(id, status, choice) {
            if (id !== page.itemId)
                return
            page.choiceStatus = status
            if (status !== "ok")
                return
            page.choice = choice
            if (page.openedChoice === "")
                page.openedChoice = choice
        }
        function onRunnerResolved(id, choice, status, resolution) {
            if (id !== page.itemId)
                return
            const next = Object.assign({}, page.answers)
            next[choice] = { status: status, resolution: resolution }
            page.answers = next
        }
        function onRunnerChoiceSet(id, choice, status) {
            if (id !== page.itemId || choice !== page.saving)
                return
            page.saving = ""
            const launch = page.launchAfterSave
            page.launchAfterSave = false
            if (status !== "ok") {
                Sfx.back()
                page.choice = page.savedBefore
                page.saveError = qsTr("The choice could not be saved. Try again.")
                return
            }
            Library.resolveRunner(page.itemId, choice)       // the preview of the stored choice, asked again
            if (launch)
                Library.launch(page.itemId)
        }
        // Stored by anyone for the signed-in profile (another screen, ruya-session).
        function onRunnerChoiceChanged(id, choice) {
            if (id === page.itemId && page.saving === "")
                page.choice = choice
        }
    }

    // ---- Focus: Try after a crash, else Runner; Try again when Library1 does not answer ----
    // The row the page put the focus on; once the player moved away from it, the page leaves the focus alone.
    property Item placed: null
    function placeFocus() {
        const want = failed ? retryRow : tryShown ? tryRow : loaded ? runnerRow : null
        if (!want || !want.visible || want.activeFocus)
            return
        if (placed && placed.visible && !placed.activeFocus && body.focusableRows().some(r => r.activeFocus))
            return
        want.focus = true
        placed = want
    }
    readonly property string focusKey: failed + "#" + loaded + "#" + tryShown
    onFocusKeyChanged: Qt.callLater(placeFocus)

    hints: body.hints

    SettingsPane {
        id: body
        objectName: "compatBody"
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.min(parent.width, 1100 * page.u)
        u: page.u
        focus: true
        onExitRequested: page.backRequested()

        SettingRow {
            objectName: "compatLoading"
            kind: "info"
            enabled: false
            u: page.u
            visible: page.loading
            label: qsTr("Loading…")
        }
        SettingRow {
            id: tryRow
            objectName: "compatTry"
            kind: "action"
            u: page.u
            visible: page.tryShown
            label: qsTr("Try the bundled runner")
            value: qsTr("It stopped unexpectedly last time.")
            onActivated: page.tryBundled()
        }
        ChoiceRow {
            id: runnerRow
            objectName: "compatRunner"
            u: page.u
            visible: page.loaded || page.failed
            dimmed: page.failed
            label: qsTr("Runner")
            options: page.failed ? [{ value: "", label: qsTr("Not available") }] : page.runnerOptions
            onEdited: value => {
                if (page.failed)
                    page.notAvailable()
                else
                    page.store(value)
            }
        }
        // The row shows the page's choice again after its own step (a refused store goes back).
        Binding {
            target: runnerRow
            property: "value"
            value: page.failed ? "" : page.choice
        }
        SettingNote {
            objectName: "compatRunnerNote"
            u: page.u
            visible: text !== ""
            text: page.runnerNote
        }
        SettingNote {
            objectName: "compatError"
            u: page.u
            visible: text !== ""
            text: page.failed ? qsTr("Runner details can't be read right now.") : page.saveError
            color: Theme.errorText
        }
        SettingRow {
            objectName: "compatStartsWith"
            kind: "info"
            u: page.u
            visible: page.loaded
            label: qsTr("Starts with")
            value: page.refused ? qsTr("Can't start") : (page.preview.playRunner ?? "")
            detail: page.refused ? "" : RunnerText.sourceWord(page.preview.playRunnerSource)
        }
        SettingNote {
            objectName: "compatRefusal"
            u: page.u
            visible: page.loaded && page.refused
            text: RunnerText.refusal(page.preview.playResolveCode ?? "")
            color: Theme.errorText
        }
        SettingRow {
            objectName: "compatTested"
            kind: "info"
            u: page.u
            visible: page.loaded && !page.refused && (page.preview.playRunnerTested ?? "") !== ""
            label: qsTr("Tested with")
            value: page.familyOf(page.preview.playRunner) + " " + (page.preview.playRunnerTested ?? "")
        }
        GroupLabel {
            objectName: "compatVersions"
            u: page.u
            visible: page.loaded
            text: qsTr("Versions")
        }
        SettingRow {
            objectName: "compatBundled"
            kind: "info"
            u: page.u
            visible: page.loaded
            label: qsTr("Bundled runner")
            value: page.hasBundled ? page.bundledAnswer.playRunner : qsTr("None")
        }
        SettingRow {
            objectName: "compatSystem"
            kind: "info"
            u: page.u
            visible: page.loaded && page.family !== ""
            label: qsTr("System runner")
            value: page.systemRunners.length > 0 ? page.systemRunners.join(", ") : qsTr("None")
        }
        SettingRow {
            id: retryRow
            objectName: "compatRetry"
            kind: "action"
            u: page.u
            visible: page.failed
            label: qsTr("Try again")
            onActivated: page.load()
        }
    }
}
