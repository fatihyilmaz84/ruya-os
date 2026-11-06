import QtQuick
import QtTest
import RuyaShell

// Store singleton against the mock backend: catalogue, search, install, update and uninstall.
Item {
    id: host
    width: 320
    height: 240

    SignalSpy { id: finished; target: Store; signalName: "jobFinished" }
    SignalSpy { id: reconciled; target: Store; signalName: "jobsReconciled" }

    // The jobs the facade showed at the moment the service's job table had been applied.
    property var jobsAtReconcile: []
    Connections {
        target: Store
        function onJobsReconciled() { host.jobsAtReconcile = Object.keys(Store.jobs) }
    }

    TestCase {
        id: tc
        name: "StoreBackend"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Store.mockReset()
            tryVerify(() => Store.catalogue.length === 12)
            tryVerify(() => Store.installed.length === 3)
            finished.clear()
            reconciled.clear()
            host.jobsAtReconcile = []
        }

        function isInstalled(id) { return Store.installed.some(a => a.id === id) }

        function test_search() {
            const all = Store.catalogue
            compare(all.length, 12)
            const sources = new Set(all.map(a => a.source))
            compare(sources.size, 3)
            const levels = new Set(all.map(a => a.controller))
            compare(levels.size, 3)
            Store.search("xyz-none")
            tryCompare(Store, "available", true)
            tryVerify(() => Store.results.length === 0)
            Store.search("chess")
            tryVerify(() => Store.results.length === 1)
            compare(Store.results[0].id, "org.example.Chess")
            Store.search("")
            tryVerify(() => Store.results.length === 12)
        }

        function test_install_patches_flags_without_a_new_search() {
            const id = "org.example.Racer"
            Store.search("")
            tryVerify(() => Store.results.length === 12)
            const searches = Store.mockSearchCount()
            Store.install(id)
            tryCompare(finished, "count", 1)
            tryVerify(() => isInstalled(id))
            tryVerify(() => Store.app(id).installed === true)
            tryVerify(() => Store.results.find(a => a.id === id).installed === true)
            compare(Store.mockSearchCount(), searches, "installing must not search again")
            Store.uninstall(id, false)
            tryCompare(finished, "count", 2)
            tryVerify(() => Store.app(id).installed === false)
            compare(Store.mockSearchCount(), searches)
        }

        function test_catalog_changed_repeats_the_last_query() {
            Store.search("chess")
            tryVerify(() => Store.results.length === 1)
            const searches = Store.mockSearchCount()
            Store.mockCatalogChanged()
            tryVerify(() => Store.mockSearchCount() === searches + 2) // the catalogue and the query
            tryVerify(() => Store.results.length === 1)
            compare(Store.results[0].id, "org.example.Chess")
            compare(Store.catalogue.length, 12)
            Store.search("")
            tryVerify(() => Store.results.length === 12)
        }

        function test_controller_filter() {
            compare(Store.controllerFilter, "any")
            Store.controllerFilter = "gamepad"
            tryVerify(() => Store.results.length === 9 && Store.results.every(a => a.controller !== "none"))
            compare(Store.catalogue.length, 12, "the catalogue stays whole")
            Store.search("editor")
            tryVerify(() => Store.results.length === 0)
            Store.controllerFilter = "any"
            tryVerify(() => Store.results.length === 1)
            Store.search("")
            tryVerify(() => Store.results.length === 12)
        }

        function test_install_lifecycle() {
            const id = "org.example.Racer"
            verify(!isInstalled(id))
            const percents = []
            // No local inside this closure: qmllint goes blind on one (T-189, scripts/lint-test-members.ps1).
            const onJobs = () => { if (Store.jobs[id]) percents.push(Store.jobs[id].percent) }
            Store.jobsChanged.connect(onJobs)
            Store.install(id)
            tryCompare(finished, "count", 1)
            Store.jobsChanged.disconnect(onJobs)
            compare(finished.signalArguments[0][0], id)
            compare(finished.signalArguments[0][1], "ok")
            verify(percents.length > 2)
            for (let i = 1; i < percents.length; ++i)
                verify(percents[i] >= percents[i - 1])
            compare(percents[percents.length - 1], 100)
            tryVerify(() => isInstalled(id))
            tryVerify(() => Store.app(id).installed)
            compare(Store.jobs[id], undefined)
        }

        // T-167: the reset drops the mock's running jobs without a JobFinished; the facade
        // must not keep the progress it had seen (a test after it saw "one job" and failed at random).
        function test_reset_drops_a_running_job() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            verify(Store.jobs[id].percent < 100, "the job is still running")
            Store.mockReset()
            compare(Object.keys(Store.jobs).length, 0)
            tryVerify(() => Store.installed.length === 3)
            wait(100)                                   // no late progress brings it back
            compare(Object.keys(Store.jobs).length, 0)
            verify(!isInstalled(id))
        }

        // T-171: the service vanishes mid-install; the job would never finish, so none is shown.
        function test_service_loss_drops_running_jobs() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            compare(Object.keys(Store.jobs).length, 0)
            wait(100)                                   // no late progress brings it back
            compare(Object.keys(Store.jobs).length, 0)
        }

        // T-188: the service restarts mid-install. It cannot resume Flatpak's transaction, so the job
        // is failed (interrupted); the facade already said so when it lost the service and says
        // nothing more when the new service's job table agrees.
        function test_restart_keeps_an_interrupted_job_failed() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            compare(finished.count, 1)
            compare(finished.signalArguments[0][0], id)
            compare(finished.signalArguments[0][1], "failed")
            Store.mockServiceRegained()
            tryCompare(reconciled, "count", 1)
            compare(host.jobsAtReconcile.length, 0)
            compare(Object.keys(Store.jobs).length, 0)
            compare(finished.count, 1, "no second verdict for the same job")
            verify(!isInstalled(id))
        }

        // T-188: Flatpak completed the install while the service was away; the hung "installing"
        // becomes "installed", not "failed, retry".
        function test_restart_finds_the_install_flatpak_completed() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            compare(finished.signalArguments[0][1], "failed", "given up at once")
            Store.mockServiceRegained([id])
            tryCompare(finished, "count", 2)
            compare(finished.signalArguments[1][0], id)
            compare(finished.signalArguments[1][1], "ok")
            tryVerify(() => isInstalled(id))
            tryVerify(() => Store.app(id).installed === true)
            compare(Object.keys(Store.jobs).length, 0)
        }

        // T-188: a job the new service runs is shown from its job table.
        function test_restart_shows_the_jobs_the_new_service_runs() {
            Store.install("org.example.Racer")
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            Store.install("org.example.Platformer")      // asked of the new service at once
            Store.mockServiceRegained()
            tryCompare(reconciled, "count", 1)
            compare(host.jobsAtReconcile.join(), "org.example.Platformer", "only the job that runs")
            tryCompare(finished, "count", 2)             // Racer failed at the loss, Platformer ends
            compare(finished.signalArguments[1][0], "org.example.Platformer")
            compare(finished.signalArguments[1][1], "ok")
            compare(Object.keys(Store.jobs).length, 0)
        }

        // T-188: what the facade shows is replaced by the job table, also when it missed a JobFinished.
        function test_job_table_replaces_a_stale_entry() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockForgetJobs()                       // the service ended it; no signal reached us
            verify(Store.jobs[id] !== undefined, "the facade still shows it")
            Store.mockServiceRegained()
            tryCompare(reconciled, "count", 1)
            compare(Object.keys(Store.jobs).length, 0)
            compare(finished.count, 0, "an app that was not given up has no verdict to correct")
        }

        // T-188: a reply that comes late must not put back what a newer reply took away.
        function test_a_late_job_table_is_dropped() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockListJobsDelayed(300)               // a snapshot in which Racer is still running
            compare(Store.mockPendingJobLists(), 1)
            Store.mockServiceLost()
            Store.mockServiceRegained()                  // the newer table: Racer interrupted
            tryCompare(reconciled, "count", 1)
            compare(Object.keys(Store.jobs).length, 0)
            tryVerify(() => Store.mockPendingJobLists() === 0, 2000)
            wait(50)
            compare(reconciled.count, 1, "the late reply was not reported")
            compare(Object.keys(Store.jobs).length, 0, "and did not bring the job back")
        }

        // T-191: the job table is a snapshot. A JobFinished that reached the shell before the reply
        // must not be undone by the reply, which still lists the job as running.
        function test_a_job_finished_before_the_table_reply_stays_finished() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockListJobsDelayed(600)               // a snapshot in which Racer still runs
            compare(Store.mockPendingJobLists(), 1)
            tryCompare(finished, "count", 1)             // the JobFinished comes first
            compare(finished.signalArguments[0][1], "ok")
            tryVerify(() => Store.mockPendingJobLists() === 0, 3000)
            tryCompare(reconciled, "count", 1)
            compare(Object.keys(Store.jobs).length, 0, "the reply did not bring a finished job back")
            compare(host.jobsAtReconcile.length, 0, "it was never shown as running after the reply")
            compare(finished.count, 1)
        }

        // T-191: a newer read that fails ends the older one too: its reply is stale.
        function test_an_old_job_table_after_a_failed_newer_one_is_dropped() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockListJobsDelayed(400)               // an older snapshot in which Racer runs
            Store.mockServiceLost()                      // the service restarted: Racer is gone
            compare(Object.keys(Store.jobs).length, 0)
            Store.mockListJobsFailing()                  // the newer read fails
            tryVerify(() => Store.mockPendingJobLists() === 0, 3000)
            compare(reconciled.count, 0, "the old table was not applied")
            compare(Object.keys(Store.jobs).length, 0, "and did not bring the job back")
        }

        // T-191: a job the shell tracks that the table lists as finished, whose JobFinished never
        // reached it, is reported (a page waiting for it would hang), not forgotten.
        function test_a_tracked_job_the_table_lists_as_finished_is_reported() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockEndJobsUnheard("network")          // it ended; the signal never came
            compare(finished.count, 0)
            Store.mockServiceRegained()                  // the table is read again
            tryCompare(reconciled, "count", 1)
            tryCompare(finished, "count", 1)
            compare(finished.signalArguments[0][0], id)
            compare(finished.signalArguments[0][1], "network")
            compare(Object.keys(Store.jobs).length, 0)
        }

        // T-191: a lost job is corrected by its own id, not by the last job its app has in the table.
        function test_a_lost_job_is_corrected_by_its_id() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            compare(finished.count, 1)
            compare(finished.signalArguments[0][1], "failed")
            Store.mockRecordFinishedJob(id, "remove", "failed")   // another client's job, later
            Store.mockServiceRegained([id])              // Flatpak completed the install after all
            tryCompare(finished, "count", 2)
            compare(finished.signalArguments[1][0], id)
            compare(finished.signalArguments[1][1], "ok", "the install, not the later remove")
            tryVerify(() => isInstalled(id))
        }

        // T-191: once a later job of the app is reported, the lost one is history.
        function test_a_lost_job_is_forgotten_when_the_app_gets_a_new_one() {
            const id = "org.example.Racer"
            Store.install(id)
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            compare(finished.count, 1)
            Store.install(id)                            // the new service runs a new job
            tryVerify(() => Store.jobs[id] !== undefined, 2000, "the new job reports progress")
            Store.mockPauseJobs(true)
            Store.mockServiceRegained([id])              // the table finds the lost install completed
            tryCompare(reconciled, "count", 1)
            compare(finished.count, 1, "no verdict for the old job while a new one runs")
            verify(Store.jobs[id] !== undefined, "the new job is the one shown")
        }

        // T-191: the installed list is a snapshot too (ruya-store answers concurrently, and
        // InstalledChanged can come before the reply of the call that caused it).
        function test_a_late_installed_list_is_dropped() {
            verify(isInstalled("org.example.Puzzle"))
            Store.mockInstalledDelayed(400)              // a snapshot with Puzzle installed
            compare(Store.mockPendingReplies(), 1)
            Store.uninstall("org.example.Puzzle", false)
            tryCompare(finished, "count", 1)
            tryVerify(() => !isInstalled("org.example.Puzzle"))
            tryVerify(() => Store.mockPendingReplies() === 0, 3000)
            verify(!isInstalled("org.example.Puzzle"), "the late snapshot was dropped")
            compare(Store.installed.length, 2)
        }

        // T-191: the same for a catalogue read that is overtaken by a newer one.
        function test_a_late_catalogue_is_dropped() {
            Store.mockCatalogueDelayed(400)              // a snapshot with Puzzle installed
            compare(Store.mockPendingReplies(), 1)
            Store.uninstall("org.example.Puzzle", false)
            tryCompare(finished, "count", 1)
            tryVerify(() => Store.app("org.example.Puzzle").installed === false)
            Store.search("")                             // a newer read of the whole catalogue
            tryVerify(() => Store.mockPendingReplies() === 0, 3000)
            compare(Store.app("org.example.Puzzle").installed, false, "the late snapshot was dropped")
        }

        function test_install_failure() {
            Store.install("org.example.Broken")
            tryCompare(finished, "count", 1)
            compare(finished.signalArguments[0][1], "failed")
            verify(!isInstalled("org.example.Broken"))
            compare(Store.app("org.example.Broken").installed, false)
        }

        function test_refused_requests() {
            Store.install("org.example.Puzzle")
            tryCompare(finished, "count", 1)
            compare(finished.signalArguments[0][1], "already-installed")
            Store.install("org.example.nope")
            tryCompare(finished, "count", 2)
            compare(finished.signalArguments[1][1], "unknown-app")
        }

        function test_update() {
            verify(Store.app("org.example.Chess").updateAvailable)
            Store.update("org.example.Chess")
            tryCompare(finished, "count", 1)
            compare(finished.signalArguments[0][1], "ok")
            tryVerify(() => !Store.app("org.example.Chess").updateAvailable)
            verify(isInstalled("org.example.Chess"))
        }

        function test_uninstall() {
            Store.uninstall("org.example.Puzzle", true)
            tryCompare(finished, "count", 1)
            compare(finished.signalArguments[0][1], "ok")
            tryVerify(() => !isInstalled("org.example.Puzzle"))
            verify(Store.mockDataDeleted("org.example.Puzzle"))
            Store.uninstall("org.example.Editor", false)
            tryCompare(finished, "count", 2)
            tryVerify(() => !isInstalled("org.example.Editor"))
            verify(!Store.mockDataDeleted("org.example.Editor"))
        }
    }
}
