import QtQuick
import QtTest
import RuyaShell

// Store singleton against the mock backend: catalogue, search, install, update and uninstall.
Item {
    id: host
    width: 320
    height: 240

    SignalSpy { id: finished; target: Store; signalName: "jobFinished" }

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
            const onJobs = () => { const j = Store.jobs[id]; if (j) percents.push(j.percent) }
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
