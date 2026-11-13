import QtQuick
import QtTest
import RuyaShell

// Controller profiles (RUY-42, 06 §7, api/dbus/org.ruyaos.Input1.xml): the client's table of the
// profile members is the XML's (names, argument order), the mock records every call by those names
// and answers with the contract's status strings, and the export and import helpers move a profile
// to and from a USB drive through Storage (SaveReport, and the new ListFiles and ReadFile with the
// 64 KiB cap). No UI: the pages are RUY-465.
Item {
    id: host
    width: 1280
    height: 720

    SignalSpy { id: listedSpy; target: Input; signalName: "profilesListed" }
    SignalSpy { id: fetchedSpy; target: Input; signalName: "profileFetched" }
    SignalSpy { id: savedSpy; target: Input; signalName: "profileSaved" }
    SignalSpy { id: validatedSpy; target: Input; signalName: "profileValidated" }
    SignalSpy { id: deletedSpy; target: Input; signalName: "profileDeleted" }
    SignalSpy { id: assignedSpy; target: Input; signalName: "profileAssigned" }
    SignalSpy { id: effectiveSpy; target: Input; signalName: "effectiveProfileFetched" }
    SignalSpy { id: changedSpy; target: Input; signalName: "profilesChanged" }
    SignalSpy { id: exportSpy; target: Input; signalName: "exportFinished" }
    SignalSpy { id: importSpy; target: Input; signalName: "importFinished" }
    SignalSpy { id: filesSpy; target: Storage; signalName: "filesListed" }
    SignalSpy { id: readSpy; target: Storage; signalName: "fileRead" }

    TestCase {
        id: tc
        name: "InputProfiles"
        when: windowShown

        readonly property string me: "p2"

        function init() {
            Input.mockFail(false)
            Input.mockResetProfiles()
            Input.mockClearProfileCalls()
            Storage.mockReset()
            for (const spy of [listedSpy, fetchedSpy, savedSpy, validatedSpy, deletedSpy, assignedSpy, effectiveSpy,
                               changedSpy, exportSpy, importSpy, filesSpy, readSpy])
                spy.clear()
        }

        function cleanup() {
            Input.mockFail(false)
        }

        function profile(id, extra) {
            const p = { schema_version: 1, id: id, name: "Mine " + id, scope: { type: "global" } }
            for (const k in (extra || {}))
                p[k] = extra[k]
            return JSON.stringify(p)
        }

        // The last answer of a spy, once it has `n` answers.
        function answer(spy, n) {
            tryCompare(spy, "count", n === undefined ? 1 : n)
            return spy.signalArguments[spy.count - 1]
        }

        function save(json) {
            const before = savedSpy.count
            Input.saveProfile(tc.me, json)
            return answer(savedSpy, before + 1)
        }

        function list() {
            const before = listedSpy.count
            Input.listProfiles(tc.me)
            const a = answer(listedSpy, before + 1)
            compare(a[1], "ok")
            return a[2]
        }

        function plugStick() {
            Storage.mockPlugStick()
            tryVerify(() => Storage.volumes.some(v => v.id === "vol-stick"))
        }

        // ---- the contract ----------------------------------------------------------------------

        // Every profile member of the client is the XML's method, with the XML's in- and
        // out-arguments in the XML's order (the D-Bus client builds its calls from this table).
        function test_the_client_table_is_the_xml() {
            const xhr = new XMLHttpRequest()
            xhr.open("GET", Qt.resolvedUrl("../../api/dbus/org.ruyaos.Input1.xml"), false)
            xhr.send()
            const xml = xhr.responseText.replace(/<!--[\s\S]*?-->/g, "")
            verify(xml.indexOf("<interface") >= 0, "the XML was read: " + xhr.responseText.length + " bytes")
            const methods = Input.profileMethods()
            compare(methods.map(m => m.name),
                    ["ListProfiles", "GetProfile", "SaveProfile", "ValidateProfile", "DeleteProfile", "AssignProfile",
                     "GetEffectiveProfile", "SetConfirmButton"])
            for (const m of methods) {
                const body = new RegExp('<method name="' + m.name + '">([\\s\\S]*?)</method>').exec(xml)
                verify(body, m.name + " is in the XML")
                const args = []
                const re = /<arg name="([a-z_]+)" type="([^"]+)" direction="(in|out)"\/>/g
                let a
                while ((a = re.exec(body[1])) !== null)
                    args.push({ name: a[1], type: a[2], dir: a[3] })
                compare(m.in, args.filter(x => x.dir === "in").map(x => x.name), m.name + " in-arguments")
                compare(m.out, args.filter(x => x.dir === "out").map(x => x.name), m.name + " out-arguments")
                verify(args.filter(x => x.dir === "in").every(x => x.type === "s"), m.name + ": every in-argument is a string")
            }
            verify(/<property name="ConfirmButton" type="s" access="read"\/>/.test(xml), "the ConfirmButton property (RUY-40)")
            verify(/<signal name="ActiveInputChanged">\s*<arg name="device_id" type="s"\/>\s*<arg name="family" type="s"\/>/.test(xml),
                   "ActiveInputChanged(device_id, family)")
            verify(/<signal name="ProfilesChanged">\s*<arg name="profile" type="s"\/>/.test(xml), "ProfilesChanged(profile)")
        }

        // Each facade call reaches the service with its arguments under the XML's names.
        function test_every_call_carries_the_xml_names() {
            Input.listProfiles("p2")
            Input.getProfile("p2", "nintendo")
            Input.saveProfile("p2", "{}")
            Input.validateProfile("{}")
            Input.deleteProfile("p2", "mine")
            Input.assignProfile("p2", "global", "", "nintendo")
            Input.getEffectiveProfile("p2", "dev-dualsense", "org.example.Racer")
            const calls = Input.mockProfileCalls()
            compare(calls.map(c => c.method),
                    ["ListProfiles", "GetProfile", "SaveProfile", "ValidateProfile", "DeleteProfile", "AssignProfile",
                     "GetEffectiveProfile"])
            compare(calls[0].args, { profile: "p2" })
            compare(calls[1].args, { profile: "p2", profile_id: "nintendo" })
            compare(calls[2].args, { profile: "p2", json: "{}" })
            compare(calls[3].args, { json: "{}" })
            compare(calls[4].args, { profile: "p2", profile_id: "mine" })
            compare(calls[5].args, { profile: "p2", scope: "global", scope_id: "", profile_id: "nintendo" })
            compare(calls[6].args, { profile: "p2", device_id: "dev-dualsense", app_id: "org.example.Racer" })
            const table = Input.profileMethods()
            for (let i = 0; i < calls.length; ++i)
                compare(Object.keys(calls[i].args).sort(), table[i].in.slice().sort(), calls[i].method + ": the table's names")
        }

        function test_the_builtins_and_the_summary_keys() {
            const rows = list()
            compare(rows.map(r => r.id), ["default", "nintendo"])
            const keys = ["assigned", "builtin", "changed", "global_slot", "id", "inherits", "layout", "left_stick_changed",
                          "match_device", "match_family", "name", "remapped", "right_stick_changed", "scope", "scope_id"]
            compare(Object.keys(rows[0]).sort(), keys)
            // The XML header lists the same keys (RUY-545 added global_slot).
            const xhr = new XMLHttpRequest()
            xhr.open("GET", Qt.resolvedUrl("../../api/dbus/org.ruyaos.Input1.xml"), false)
            xhr.send()
            const header = /Profile summary \(a\{sv\}\), keys:([\s\S]*?)ListProfiles lists/.exec(xhr.responseText)
            verify(header, "the summary keys are in the XML header")
            const listed = []
            const re = /^ {4}([a-z_]+) +[sbu]( |$)/gm
            let k
            while ((k = re.exec(header[1])) !== null)
                listed.push(k[1])
            compare(listed.sort(), keys)
            compare(rows[0].global_slot, "", "a built-in: all controllers' slot")
            compare(rows[0].builtin, true)
            compare(rows[0].changed, false)
            compare(rows[1].layout, "nintendo")
            compare(rows[1].remapped, 4)
            compare(rows[1].changed, true)
            Input.getProfile(tc.me, "nintendo")
            const got = answer(fetchedSpy)
            compare(got[2], "ok")
            compare(JSON.parse(got[3]).mappings.length, 4)
        }

        // What the pages show without another call: Default / Changed, the layout, the count of
        // changed buttons, which stick changed, which profile is the console profile's.
        function test_a_saved_and_assigned_profile_reads_as_changed() {
            const a = save(profile("mine", {
                inherits: "nintendo",
                mappings: [{ from: "west", to: { type: "button", code: "south" } },
                           { from: "l1", to: { type: "button", code: "l1" } }],
                settings: { left_stick: { inner_deadzone: 0.12, curve: "precise" } }
            }))
            compare(a[1], "ok")
            compare(a[2], "mine")
            compare(a[3], [])
            tryCompare(changedSpy, "count", 1)
            compare(changedSpy.signalArguments[0][0], tc.me)
            Input.assignProfile(tc.me, "global", "", "mine")
            compare(answer(assignedSpy)[4], "ok")
            tryCompare(changedSpy, "count", 2)
            const mine = list().find(r => r.id === "mine")
            compare(mine.assigned, true)
            compare(mine.layout, "nintendo")
            compare(mine.remapped, 1, "west differs from the layout; l1 to itself does not")
            compare(mine.left_stick_changed, true)
            compare(mine.right_stick_changed, false)
            compare(mine.changed, true)
            compare(mine.inherits, "nintendo")
            Input.getEffectiveProfile(tc.me, "", "")
            const eff = answer(effectiveSpy)
            compare(eff[3], "ok")
            compare(eff[5], ["mine", "nintendo", "default"])
            const flat = JSON.parse(eff[4])
            verify(flat.inherits === undefined, "flattened")
            compare(flat.settings.left_stick.inner_deadzone, 0.12)
            compare(flat.settings.left_stick.outer_deadzone, 0.02, "defaults filled in")
        }

        // RUY-545, the cases of book.rs: one global profile per slot ("" all controllers,
        // "family:<f>", "device:<id>"); a pad takes its device's, else its family's, else all's.
        function test_each_pad_takes_the_profile_of_its_most_specific_slot() {
            const ds = "bluetooth-054c-0ce6-3f2a9c41d0b7"
            const pro = "bluetooth-057e-2009-b7c0e1f2a3d4"
            const xbox = "usb-045e-0b12-8e01c2d4a9f3"
            Input.mockResetDevices()
            tryVerify(() => Input.devicesState === "ok" && Input.devices.length === 3)
            const south = to => [{ from: "south", to: { type: "button", code: to } }]
            compare(save(profile("a", { match: { device: ds }, mappings: south("east") }))[1], "ok")
            compare(save(profile("n", { match: { family: "nintendo" }, mappings: south("west") }))[1], "ok")
            compare(save(profile("every", { mappings: south("north") }))[1], "ok")
            let n = 0
            const assign = (slot, id) => {
                Input.assignProfile(tc.me, "global", slot, id)
                return answer(assignedSpy, ++n)[4]
            }
            let e = 0
            const chainOf = device => {
                Input.getEffectiveProfile(tc.me, device, "")
                return answer(effectiveSpy, ++e)[5]
            }
            compare(assign("device:" + ds, "a"), "ok")
            compare(assign("family:nintendo", "n"), "ok")
            compare(chainOf(ds), ["a", "default"], "the DualSense: its own")
            compare(chainOf(pro), ["n", "default"], "the Pro Controller: its family's")
            compare(chainOf(xbox), ["default"], "the Xbox pad: nothing applies")
            compare(assign("", "every"), "ok")
            compare(chainOf(xbox), ["every", "default"])
            compare(chainOf(ds), ["a", "default"], "the device's slot over all's")
            const slots = list().filter(r => r.assigned).map(r => r.global_slot + "=" + r.id).sort()
            compare(slots, ["=every", "device:" + ds + "=a", "family:nintendo=n"])
            compare(assign("family:nintendo", ""), "ok")
            compare(chainOf(pro), ["every", "default"], "emptying the family's slot leaves the others")
            compare(chainOf(ds), ["a", "default"])
            // A slot takes only a profile whose match names it; a malformed scope_id is invalid.
            for (const [slot, id] of [["", "a"], ["", "n"], ["family:xbox", "n"], ["family:nintendo", "a"],
                                      ["family:nintendo", "every"], ["device:" + pro, "a"], ["family:nintendo", "nintendo"]])
                compare(assign(slot, id), "invalid", id + " in '" + slot + "'")
            for (const slot of ["all", "family:", "family:sega", "device:", "device:USB", "game:x"])
                compare(assign(slot, ""), "invalid", "'" + slot + "' is no slot")
            // A save that changes an assigned profile's match takes it out of its old slot.
            compare(save(profile("a", { match: { family: "playstation" }, mappings: south("east") }))[1], "ok")
            const a = list().find(r => r.id === "a")
            compare([a.assigned, a.global_slot], [false, "family:playstation"])
            compare(chainOf(ds), ["every", "default"])
        }

        function test_the_status_strings() {
            Input.listProfiles("../etc")
            compare(answer(listedSpy)[1], "unknown-profile")
            let a = save('{"schema_version":1,"id":"x","name":"","scope":{"type":"global"},"script":1}')
            compare(a[1], "invalid")
            verify(a[3].some(e => e.indexOf("/name: ") === 0), a[3])
            verify(a[3].some(e => e.indexOf("unknown field script") >= 0), a[3])
            a = save(profile("default"))
            compare(a[1], "not-allowed")
            compare(a[3], ['/id: "default" is a built-in profile'])
            a = save(profile("kid", { inherits: "ghost" }))
            compare(a[1], "invalid")
            compare(a[3], ['/inherits: no profile "ghost"'])
            a = save(profile("big", { description: "x".repeat(70000) }))
            compare(a[1], "invalid")
            verify(a[3][0].indexOf("larger than 65536 bytes") >= 0, a[3])
            Input.validateProfile(profile("fine"))
            compare(answer(validatedSpy)[0], "ok")
            Input.validateProfile('{"schema_version":1,"id":"p","name":"P","scope":{"type":"global"},"mappings":[{"from":"south","to":{"type":"button","code":"jump"}}]}')
            const v = answer(validatedSpy, 2)
            compare(v[0], "invalid")
            compare(v[1], ['/mappings/0/to/code: "jump" is not a button'])
            Input.deleteProfile(tc.me, "nintendo")
            compare(answer(deletedSpy)[2], "not-allowed")
            Input.deleteProfile(tc.me, "nope")
            compare(answer(deletedSpy, 2)[2], "unknown-profile")
            Input.assignProfile(tc.me, "game", "org.example.Racer", "default")
            compare(answer(assignedSpy)[4], "invalid", "game assignments are RUY-43")
            Input.assignProfile(tc.me, "global", "", "nope")
            compare(answer(assignedSpy, 2)[4], "unknown-profile")
            Input.getEffectiveProfile(tc.me, "no-such-pad", "")
            compare(answer(effectiveSpy)[3], "unknown-device")
            Input.getProfile(tc.me, "nope")
            compare(answer(fetchedSpy)[2], "unknown-profile")
            compare(changedSpy.count, 0, "nothing changed")
            Input.mockFail(true)
            Input.listProfiles(tc.me)
            compare(answer(listedSpy, 2)[1], "failed")
            Input.saveProfile(tc.me, profile("x"))
            compare(answer(savedSpy, 5)[1], "failed")
        }

        function test_deleting_a_parent_reparents_its_children() {
            compare(save(profile("base", { inherits: "nintendo" }))[1], "ok")
            compare(save(profile("kid", { inherits: "base" }))[1], "ok")
            Input.deleteProfile(tc.me, "base")
            compare(answer(deletedSpy)[2], "ok")
            const kid = list().find(r => r.id === "kid")
            compare(kid.inherits, "nintendo")
            compare(kid.layout, "nintendo")
        }

        // ---- moving a profile to and from a USB drive -----------------------------------------

        function test_export_writes_one_file_onto_the_stick() {
            plugStick()
            save(profile("mine", { inherits: "nintendo" }))
            const name = Input.exportFileName(tc.me)
            verify(/^RuyaOS-controls-p2-\d{4}-\d{2}-\d{2}\.json$/.test(name), name)
            Input.exportProfile(tc.me, "mine", "vol-stick")
            Input.exportProfile(tc.me, "mine", "vol-stick")
            let a = answer(exportSpy)
            compare(a[3], "busy", "one export at a time")
            a = answer(exportSpy, 2)
            compare(a[3], "ok")
            compare(a[4], name)
            const files = Storage.mockSavedFiles()
            compare(Object.keys(files), [name])
            compare(JSON.parse(files[name]).id, "mine")
            compare(JSON.parse(files[name]).inherits, "nintendo")
            Input.exportProfile(tc.me, "nope", "vol-stick")
            compare(answer(exportSpy, 3)[3], "unknown-profile")
            Input.exportProfile(tc.me, "mine", "vol-internal")
            compare(answer(exportSpy, 4)[3], "unsupported", "not a removable volume")
        }

        function test_import_reads_validates_saves_and_assigns() {
            plugStick()
            Storage.mockSetFile("vol-stick", "mine.json", profile("from-usb", { inherits: "nintendo" }), 1000)
            Input.importProfile(tc.me, "vol-stick", "mine.json")
            const a = answer(importSpy)
            compare(a[3], "ok")
            compare(a[4], "from-usb")
            compare(a[5], [])
            compare(Storage.mockReadCalls(), ["vol-stick/mine.json"])
            const row = list().find(r => r.id === "from-usb")
            verify(row, "saved")
            compare(row.assigned, true, "a global profile applies once imported")
            const calls = Input.mockProfileCalls().map(c => c.method)
            compare(calls.slice(0, 3), ["ValidateProfile", "SaveProfile", "AssignProfile"])
            // A file for one family goes to that family's slot (RUY-545).
            Storage.mockSetFile("vol-stick", "nin.json", profile("for-nintendo", { match: { family: "nintendo" } }), 1001)
            Input.importProfile(tc.me, "vol-stick", "nin.json")
            compare(answer(importSpy, 2)[3], "ok")
            const assigns = Input.mockProfileCalls().filter(c => c.method === "AssignProfile")
            compare(assigns[assigns.length - 1].args.scope_id, "family:nintendo")
            const rows = list()
            verify(rows.find(r => r.id === "for-nintendo").assigned, "assigned to its slot")
            verify(rows.find(r => r.id === "from-usb").assigned, "the other slot keeps its profile")
        }

        function test_import_refusals() {
            plugStick()
            // Over 64 KiB: refused before it is read.
            Storage.mockSetFile("vol-stick", "big.json", profile("big", { description: "x" }) + " ".repeat(65536), 1)
            Input.importProfile(tc.me, "vol-stick", "big.json")
            compare(answer(importSpy)[3], "too-large")
            // Not a profile: the service's reasons come back (and go to the journal).
            Storage.mockSetFile("vol-stick", "bad.json", '{"schema_version":2}', 1)
            Input.importProfile(tc.me, "vol-stick", "bad.json")
            let a = answer(importSpy, 2)
            compare(a[3], "invalid")
            verify(a[5].length > 0, "with the service's lines")
            // A built-in's id.
            Storage.mockSetFile("vol-stick", "builtin.json", profile("nintendo"), 1)
            Input.importProfile(tc.me, "vol-stick", "builtin.json")
            compare(answer(importSpy, 3)[3], "not-allowed")
            Input.importProfile(tc.me, "vol-stick", "missing.json")
            compare(answer(importSpy, 4)[3], "not-found")
            Storage.mockSetReadStatus("not-text")
            Storage.mockSetFile("vol-stick", "binary.json", "x", 1)
            Input.importProfile(tc.me, "vol-stick", "binary.json")
            compare(answer(importSpy, 5)[3], "not-text")
            Storage.mockSetReadStatus("")
            Input.importProfile(tc.me, "vol-stick", "../etc/passwd")
            compare(answer(importSpy, 6)[3], "invalid", "never a path")
            compare(list().map(r => r.id), ["default", "nintendo"], "nothing was saved")
        }

        function test_an_export_imports_again() {
            plugStick()
            save(profile("mine", { settings: { right_stick: { invert_y: true } } }))
            Input.exportProfile(tc.me, "mine", "vol-stick")
            compare(answer(exportSpy)[3], "ok")
            Input.deleteProfile(tc.me, "mine")
            answer(deletedSpy)
            Input.importProfile(tc.me, "vol-stick", Input.exportFileName(tc.me))
            compare(answer(importSpy)[3], "ok")
            const row = list().find(r => r.id === "mine")
            compare(row.right_stick_changed, true)
        }

        function test_list_files_newest_first() {
            plugStick()
            Storage.mockSetFile("vol-stick", "old.json", "{}", 100)
            Storage.mockSetFile("vol-stick", "NEW.JSON", "{}", 200)
            Storage.mockSetFile("vol-stick", "notes.txt", "x", 300)
            Storage.mockSetFile("vol-stick", ".hidden.json", "{}", 400)
            Storage.listFiles("vol-stick", ".json")
            tryCompare(filesSpy, "count", 1)
            let a = filesSpy.signalArguments[0]
            compare(a[2], "ok")
            compare(a[3].map(f => f.name), ["NEW.JSON", "old.json"])
            compare(a[3][1].modified, 100)
            compare(a[3][1].sizeBytes, 2)
            Storage.listFiles("vol-stick", "json")
            tryCompare(filesSpy, "count", 2)
            compare(filesSpy.signalArguments[1][2], "invalid")
            Storage.listFiles("vol-internal", ".json")
            tryCompare(filesSpy, "count", 3)
            compare(filesSpy.signalArguments[2][2], "unsupported")
            Storage.listFiles("vol-nope", ".json")
            tryCompare(filesSpy, "count", 4)
            compare(filesSpy.signalArguments[3][2], "unknown-volume")
            Storage.readFile("vol-stick", "old.json", 0)
            tryCompare(readSpy, "count", 1)
            compare(readSpy.signalArguments[0][2], "invalid", "max_bytes 0")
            Storage.readFile("vol-stick", "old.json", 100)
            tryCompare(readSpy, "count", 2)
            compare(readSpy.signalArguments[1][2], "ok")
            compare(readSpy.signalArguments[1][3], "{}")
        }
    }
}
