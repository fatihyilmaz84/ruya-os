import QtQuick
import QtTest
import RuyaShell

// Play singleton against the mock backend (api/dbus/org.ruyaos.Play1.xml, spec 05 §7.3): sources,
// inspecting every fixture, the install job from staging to installed, every failure status, cancel,
// verify, a job that outlives its page and the loss of the service. The mock is reset before every
// test. No UI exists yet (RUY-98), so the singleton is driven directly.
Item {
    id: host
    width: 320
    height: 240

    // Everything the singleton said, in order.
    property var answers: []    // { op, key, status }
    property var finished: []   // { key, status }
    property var progress: []   // { key, percent, phase }
    property var infos: []      // { path, info }
    property var methodSeen: [] // statuses of answered()
    property var jobSeen: []    // statuses of jobFinished()

    Connections {
        target: Play
        function onAnswered(op, key, status) {
            host.answers = host.answers.concat([{ op: op, key: key, status: status }])
            if (host.methodSeen.indexOf(status) < 0)
                host.methodSeen = host.methodSeen.concat([status])
        }
        function onJobFinished(key, status) {
            host.finished = host.finished.concat([{ key: key, status: status }])
            if (host.jobSeen.indexOf(status) < 0)
                host.jobSeen = host.jobSeen.concat([status])
        }
        function onInspected(path, info) { host.infos = host.infos.concat([{ path: path, info: info }]) }
        function onJobsChanged() {
            for (const key of Object.keys(Play.jobs))
                host.progress = host.progress.concat([{ key: key, percent: Play.jobs[key].percent, phase: Play.jobs[key].phase }])
        }
    }

    TestCase {
        id: tc
        name: "Play"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Play.mockReset()
            tryCompare(Play, "available", true)
            tryVerify(() => Play.sources.length === 13)
            host.answers = []
            host.finished = []
            host.progress = []
            host.infos = []
            host.methodSeen = []
            host.jobSeen = []
        }

        function p(fixture) { return Play.mockPath(fixture) }

        function answerFor(op, key) { return host.answers.find(a => a.op === op && a.key === key) }
        function finishFor(key) { return host.finished.find(f => f.key === key) }
        function progressOf(key) { return host.progress.filter(e => e.key === key) }

        // Runs a call and returns the method status of its answer (top-level: qmllint goes blind on
        // locals declared inside a nested function, scripts/lint-test-members.ps1).
        function runCall(op, key, call) {
            host.answers = host.answers.filter(a => !(a.op === op && a.key === key))
            call()
            tryVerify(() => answerFor(op, key) !== undefined, 2000, op + " " + key + " answered")
            return answerFor(op, key).status
        }

        function inspect(fixture) {
            const path = p(fixture)
            host.infos = []
            compare(runCall("inspect", path, () => Play.inspect(path)), "ok")
            tryVerify(() => host.infos.length === 1)
            compare(host.infos[0].path, path)
            return host.infos[0].info
        }

        // Installs a fixture as an admin and returns the status the job finished with.
        function installFixture(fixture) {
            const path = p(fixture)
            compare(runCall("install", path, () => Play.install(path, true)), "ok")
            tryVerify(() => finishFor(path) !== undefined, 5000, fixture + " finished")
            return finishFor(path).status
        }

        function test_sources_are_data_only() {
            const names = Play.sources.map(s => s.name).sort()
            compare(names.length, 13)
            verify(names.indexOf("starhopper") >= 0 && names.indexOf("pixelforest.play.zip") >= 0)
            const s = Play.sources.find(x => x.name === "pixelforest.play.zip")
            compare(s.kind, "zip")
            compare(s.drive, "vol-stick")
            compare(s.driveLabel, "STICK")
            compare(s.path, p("pixelforest.play.zip"))
            compare(Play.sources.find(x => x.name === "starhopper").kind, "folder")
            // Listing opened nothing: no inspection happened, no job exists.
            compare(host.infos.length, 0)
            compare(Object.keys(Play.jobs).length, 0)
        }

        function test_sources_follow_the_drive() {
            Play.mockSetDriveMounted(false)
            tryVerify(() => Play.sources.length === 0, 2000, "unmounted: no candidates")
            compare(runCall("inspect", p("starhopper"), () => Play.inspect(p("starhopper"))), "unknown-source")
            Play.mockSetDriveMounted(true)
            tryVerify(() => Play.sources.length === 13, 2000, "mounted again")
        }

        function test_inspect_wine_game_has_every_field() {
            const i = inspect("starhopper")
            compare(i.id, "com.example.starhopper")
            compare(i.name, "Star Hopper")
            compare(i.version, "1.142.0")
            compare(i.build, 142)
            compare(i.developer, "Example Games")
            compare(i.genres, ["shooter", "space"])
            compare(i.players, "1-2")
            compare(i.controller, "full")
            compare(i.ageLabel, "12+")
            compare(i.size, 4800 * 1024 * 1024)
            compare(i.requirement, "ok")
            compare(i.verdict, "ok")
            compare(i.tier, "developer")
            compare(i.signerKeyId, "3f9a41c07be2d6058e21b4a9d0c7f312")
            compare(i.signerKeyId.length, 32)
            compare(i.signerName, "Example Games")
            compare(i.keyState, "new")
            compare(i.permissions.map(x => x.key),
                    ["input:controllers+keyboard-mouse", "network", "removable_media:read", "multiarch", "gamemode",
                     "network+removable_media"])
            compare(i.permissions.map(x => x.risk), ["low", "medium", "medium", "medium", "low", "high"],
                    "the service lists the high-risk pair last (RUY-864)")
            verify(i.permissions[1].words.length > 0)
            verify(i.art.icon.length > 0 && i.art.card.length > 0)
            compare(i.screenshots.length, 1)
            compare(i.revoked, false)
            compare(i.installedBuild, 0)
            compare(i.problems.length, 0)
            compare(i.gate, "admin-pin-warning", "developer tier + the network/removable-media pair = high")
            compare(i.updateKnown, false, "not installed: no update keys")
            compare(i.permissionsAdded.length, 0)
            compare(i.addsHighRisk, false)
        }

        function test_inspect_the_other_fixtures() {
            let i = inspect("pixelforest.play.zip")
            compare(i.tier, "official")
            compare(i.keyState, "same")
            compare(i.installedBuild, 2, "build 2 is installed, this is build 3")
            compare(i.build, 3)
            compare(i.verdict, "ok")
            compare(i.updateKnown, true, "an update of the installed build")
            compare(i.permissionsRemoved.map(x => x.key), ["network"])
            compare(i.permissionsAdded.length, 0)
            compare(i.addsHighRisk, false)

            i = inspect("homebrew")
            compare(i.tier, "unverified")
            compare(i.signerKeyId, "")
            compare(i.keyState, "")
            compare(i.ageLabel, "", "no age label declared: not 'all'")
            compare(i.verdict, "needs-developer-mode")

            i = inspect("oldbad")
            compare(i.revoked, true)
            compare(i.verdict, "revoked")

            i = inspect("broken")
            compare(i.verdict, "invalid-package")
            compare(i.problems.map(x => x.code), ["package.hash_mismatch", "package.missing_file"])
            compare(i.problems[0].path, "data/levels.pak")

            i = inspect("rawaccess.play.zip")
            compare(i.permissions.filter(x => x.risk === "high").map(x => x.key), ["input:all-devices", "devel"])
            compare(i.gate, "admin-pin-warning", "developer tier, high risk")

            i = inspect("impostor")
            compare(i.keyState, "different")
            compare(i.verdict, "different-developer")
            verify(i.signerKeyId !== "3f9a41c07be2d6058e21b4a9d0c7f312")

            compare(inspect("tampered").verdict, "bad-signature")

            i = inspect("future")
            compare(i.requirement, "unsupported")
            compare(i.verdict, "unsupported")
            compare(i.problems[0].code, "format.too_new")
        }

        function test_developer_mode_changes_the_verdict() {
            compare(inspect("homebrew").verdict, "needs-developer-mode")
            Play.mockSetDeveloperMode(true)
            compare(inspect("homebrew").verdict, "ok")
            compare(installFixture("homebrew"), "ok")
        }

        function test_an_unverified_package_with_a_high_request_is_refused_whatever_developer_mode_says() {
            for (const mode of [false, true]) {
                Play.mockSetDeveloperMode(mode)
                const i = inspect("rawunverified")
                compare(i.verdict, "invalid-package", "developer mode " + mode)
                compare(i.gate, "", "no gate above the ceiling")
                const refused = i.problems.filter(x => x.code === "ceiling.refused")
                compare(refused.length, 1)
                compare(refused[0].path, "/permissions/devel", "it names the request")
                compare(installFixture("rawunverified"), "invalid-package", "developer mode " + mode)
            }
        }

        function test_install_runs_to_ok_with_monotonic_progress() {
            const path = p("starhopper")
            compare(installFixture("starhopper"), "ok")
            const events = progressOf(path)
            verify(events.length >= 10, "progress was reported: " + events.length)
            for (let n = 1; n < events.length; ++n)
                verify(events[n].percent >= events[n - 1].percent, "percent never decreases at " + n)
            compare(events[events.length - 1].percent, 100)
            // The phases come in the contract's order and none repeats.
            const order = ["staging", "verifying", "vetting-art", "committing", "installing"]
            const phases = events.map(e => e.phase).filter((ph, n, all) => n === 0 || all[n - 1] !== ph)
            compare(phases, order)
            compare(Object.keys(Play.jobs).length, 0, "a finished job is not shown as running")
            // One job: a single finish for the package.
            compare(host.finished.filter(f => f.key === path).length, 1)
            // The package is installed now.
            compare(inspect("starhopper").installedBuild, 142)
        }

        function test_every_failure_status_reaches_job_finished() {
            const expected = {
                "homebrew": "needs-developer-mode",
                "oldbad": "revoked",
                "broken": "invalid-package",
                "impostor": "different-developer",
                "tampered": "bad-signature",
                "future": "unsupported",
                "hugegame.play.zip": "disk-full",
                "flaky": "failed"
            }
            for (const fixture of Object.keys(expected))
                compare(installFixture(fixture), expected[fixture], fixture)
            // A package that failed is not installed, and a failure shows its progress up to the cause.
            compare(inspect("broken").installedBuild, 0)
            const last = progressOf(p("flaky"))
            verify(last.length > 0 && last[last.length - 1].phase === "committing", "flaky fails while committing")
            compare(progressOf(p("tampered")).pop().phase, "verifying")
            compare(Object.keys(Play.jobs).length, 0)
        }

        function test_method_statuses() {
            const path = p("starhopper")
            compare(runCall("install", "relative/path", () => Play.install("relative/path", true)), "invalid")
            compare(runCall("install", "/nowhere/x", () => Play.install("/nowhere/x", true)), "unknown-source")
            compare(runCall("install", path, () => Play.install(path, false)), "forbidden")
            compare(Object.keys(Play.jobs).length, 0, "a refused install started nothing")
            compare(host.finished.length, 0, "a refused install is not a job")
            compare(runCall("inspect", "relative", () => Play.inspect("relative")), "invalid")
            compare(runCall("verify", "", () => Play.verify("")), "invalid")
            compare(runCall("verify", "play.com.example.nothing", () => Play.verify("play.com.example.nothing")), "unknown-app")
            compare(runCall("cancel", "nope", () => Play.cancel("nope")), "unknown-job")

            Play.mockPauseJobs(true)
            compare(runCall("install", path, () => Play.install(path, true)), "ok")
            compare(runCall("install", path, () => Play.install(path, true)), "busy", "the same package twice")
            compare(runCall("cancel", path, () => Play.cancel(path)), "ok")
            tryVerify(() => finishFor(path) !== undefined)
            compare(finishFor(path).status, "cancelled")
            Play.mockPauseJobs(false)
        }

        function test_cancel_works_until_committing() {
            const path = p("starhopper")
            Play.mockPauseAtPercent(25)
            Play.install(path, true)
            tryVerify(() => progressOf(path).some(e => e.phase === "verifying"), 5000)
            compare(runCall("cancel", path, () => Play.cancel(path)), "ok")
            tryVerify(() => finishFor(path) !== undefined)
            compare(finishFor(path).status, "cancelled")
            compare(Object.keys(Play.jobs).length, 0)
            compare(inspect("starhopper").installedBuild, 0, "a cancelled install installs nothing")

            host.finished = []
            host.progress = []
            Play.mockPauseJobs(false)
            Play.mockPauseAtPercent(60)
            Play.install(path, true)
            tryVerify(() => progressOf(path).some(e => e.phase === "committing"), 5000)
            compare(runCall("cancel", path, () => Play.cancel(path)), "too-late")
            Play.mockPauseJobs(false)
            tryVerify(() => finishFor(path) !== undefined, 5000)
            compare(finishFor(path).status, "ok", "past the point of no return the job completes")
        }

        function test_verify() {
            const app = "play.com.example.pixelforest"
            compare(runCall("verify", app, () => Play.verify(app)), "ok")
            tryVerify(() => finishFor(app) !== undefined, 5000)
            compare(finishFor(app).status, "ok")
            for (const e of progressOf(app))
                compare(e.phase, "verifying", "a verify job only reports verifying")

            host.finished = []
            Play.mockCorruptInstalled(app)
            compare(runCall("verify", app, () => Play.verify(app)), "ok")
            tryVerify(() => finishFor(app) !== undefined, 5000)
            compare(finishFor(app).status, "invalid-package")
        }

        function test_a_job_survives_the_page_closing() {
            // A page asks for the install and goes away: nothing listens to it any more, the job
            // lives in the singleton and its progress and result are still there for the next page.
            const path = p("pixelforest.play.zip")
            Play.mockPauseAtPercent(50)
            Play.install(path, true)
            tryVerify(() => Play.jobs[path] !== undefined && Play.jobs[path].percent === 50, 5000, "the running job is listed")
            compare(finishFor(path), undefined)
            // A second page opens: it sees the running job, then its result.
            Play.mockPauseJobs(false)
            tryVerify(() => finishFor(path) !== undefined, 5000)
            compare(finishFor(path).status, "ok")
            compare(Object.keys(Play.jobs).length, 0)
        }

        function test_service_loss_clears_jobs_like_the_store() {
            const path = p("starhopper")
            Play.mockPauseAtPercent(50)
            Play.install(path, true)
            tryVerify(() => Play.jobs[path] !== undefined && Play.jobs[path].percent === 50, 5000)
            Play.mockServiceLost()
            compare(Play.available, false)
            compare(Object.keys(Play.jobs).length, 0, "jobs are cleared")
            tryVerify(() => finishFor(path) !== undefined, 2000, "the page that waited gets a result")
            compare(finishFor(path).status, "failed")
            Play.mockServiceRegained()
            tryCompare(Play, "available", true)
            compare(Object.keys(Play.jobs).length, 0)
            compare(host.finished.filter(f => f.key === path).length, 1, "failed/interrupted is not reported twice")
        }

        function test_job_table_replaces_the_jobs_when_the_service_is_back() {
            const path = p("starhopper")
            Play.mockPauseJobs(true)
            Play.install(path, true)
            tryVerify(() => answerFor("install", path) !== undefined)
            Play.mockServiceRegained()   // reads the table again; the job is queued, not running
            tryVerify(() => Play.available)
            compare(Object.keys(Play.jobs).length, 0, "a queued job has no progress yet")
            Play.mockPauseJobs(false)
            tryVerify(() => finishFor(path) !== undefined, 5000)
            compare(finishFor(path).status, "ok")
        }

        // Every status in the XML's header is exercised, and none outside it: the header is the
        // single list the service, the mock and the shell's texts follow (like tst_bluetooth).
        function headerStatuses(title, next) {
            const xhr = new XMLHttpRequest()
            xhr.open("GET", Qt.resolvedUrl("../../api/dbus/org.ruyaos.Play1.xml"), false)
            xhr.send()
            const text = xhr.responseText
            const from = text.indexOf(title)
            const to = text.indexOf(next, from)
            verify(from >= 0 && to > from, "the XML header has '" + title + "' before '" + next + "'")
            const found = []
            const re = /^ {4}"([a-z-]+)" /gm
            let m
            while ((m = re.exec(text.substring(from, to))) !== null)
                found.push(m[1])
            return found.sort()
        }

        function test_contract_statuses() {
            const path = p("starhopper")
            // Methods.
            runCall("install", "x", () => Play.install("x", true))                                // invalid
            runCall("install", "/x/y", () => Play.install("/x/y", true))                          // unknown-source
            runCall("verify", "play.none", () => Play.verify("play.none"))                        // unknown-app
            runCall("cancel", "none", () => Play.cancel("none"))                                  // unknown-job
            runCall("install", path, () => Play.install(path, false))                             // forbidden
            Play.mockPauseJobs(true)
            runCall("install", path, () => Play.install(path, true))                              // ok
            runCall("install", path, () => Play.install(path, true))                              // busy
            runCall("cancel", path, () => Play.cancel(path))                                      // ok, then cancelled
            tryVerify(() => finishFor(path) !== undefined)
            Play.mockPauseJobs(false)
            Play.mockPauseAtPercent(60)
            Play.install(path, true)
            tryVerify(() => progressOf(path).some(e => e.phase === "committing"), 5000)
            runCall("cancel", path, () => Play.cancel(path))                                      // too-late
            Play.mockPauseJobs(false)
            tryVerify(() => host.jobSeen.indexOf("ok") >= 0, 5000)
            Play.mockFailNext()
            runCall("inspect", path, () => Play.inspect(path))                                    // failed
            // Jobs: the failure fixtures.
            for (const f of ["homebrew", "oldbad", "broken", "impostor", "tampered", "future", "hugegame.play.zip", "flaky"])
                installFixture(f)
            const methods = headerStatuses("Method statuses", "JobFinished statuses")
            const jobs = headerStatuses("JobFinished statuses", "Jobs are named")
            verify(methods.length >= 9 && jobs.length >= 10, "the header lists were read: " + methods + " / " + jobs)
            compare(host.methodSeen.slice().sort(), methods, "method statuses seen = the header's")
            compare(host.jobSeen.slice().sort(), jobs, "job statuses seen = the header's")
        }
    }
}
