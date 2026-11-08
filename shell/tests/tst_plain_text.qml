import QtQuick
import QtTest
import RuyaShell

// T-286: a name from outside the shell (a profile, a Bluetooth device, a drive, a Wi-Fi network, an app
// from AppStream, a toast from a service) is drawn as the characters it is, on every screen. Qt's default
// `AutoText` would render "<b>x</b>" as markup and fetch "<img>"; so every Text that can show such a
// string says `textFormat: Text.PlainText`.
//
// Each case feeds the hostile string through one mock backend, opens the screens that show it, walks the
// item tree for every Text whose text contains it and asserts `textFormat === Text.PlainText`. A case
// also asserts how many Texts it found (a case that finds nothing proves nothing). Run against the
// real service, the same strings could come from the device; the mocks only carry them.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // The controls that show a device's, a sound theme's or a wallpaper's name (the audio outputs, the
    // sound-theme rows and the wallpaper row are built from these).
    Component {
        id: rowsComponent
        Column {
            width: 900
            SettingRow { objectName: "plainRow"; label: "<b>x</b><img src=\"qrc:/none.png\">"; value: "<b>x</b><img src=\"qrc:/none.png\">" }
            ChoiceRow {
                objectName: "plainChoice"
                label: "<b>x</b><img src=\"qrc:/none.png\">"
                options: [{ value: "a", label: "<b>x</b><img src=\"qrc:/none.png\">" }]
                value: "a"
            }
            ToggleRow { objectName: "plainToggle"; label: "<b>x</b><img src=\"qrc:/none.png\">" }
        }
    }

    TestCase {
        id: tc
        name: "PlainText"
        when: windowShown

        // 33 characters; a profile name holds at most 32, so profiles get this shorter markup.
        readonly property string hostile: '<b>x</b><img src="qrc:/none.png">'
        readonly property string hostileProfile: '<b>x</b><img src="qrc:/n.png">'

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Storage.mockReset()
            Network.mockReset()
            Bluetooth.mockReset()
            Store.mockReset()
            Store.controllerFilter = "any"
            tryVerify(() => Storage.volumes.length === 2)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            clearToasts()
        }

        function cleanup() {
            Profiles.renameProfile("p1", "1234", "p1", "Player One")
            Profiles.renameProfile("p1", "1234", "p2", "Ada")
            tryVerify(() => Profiles.profiles.some(p => p.id === "p2" && p.name === "Ada")
                      && Profiles.profiles.some(p => p.id === "p1" && p.name === "Player One"))
            clearToasts()
        }

        function clearToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        // Adds to `found` every Text-like item at or below `item` whose text contains `needle`.
        function collect(item, needle, found, seen) {
            if (!item || seen.has(item))
                return
            seen.add(item)
            if (typeof item.textFormat === "number" && typeof item.text === "string" && item.text.indexOf(needle) >= 0)
                found.push(item)
            if (item.children) {
                for (let i = 0; i < item.children.length; ++i)
                    collect(item.children[i], needle, found, seen)
            }
            if (item.contentItem)
                collect(item.contentItem, needle, found, seen)
        }

        // Every Text-like item below `root` whose text contains `needle`.
        function textsWith(root, needle) {
            const found = []
            collect(root, needle, found, new Set())
            return found
        }

        function describe(item) {
            let out = item.objectName !== "" ? item.objectName : "(unnamed Text)"
            for (let p = item.parent; p && out.length < 120; p = p.parent) {
                if (p.objectName !== "") {
                    out += " in " + p.objectName
                    break
                }
            }
            return out
        }

        // At least `minimum` Texts (within 3 s: a model fills in a moment after the mock changes) show the
        // string, and every one of them is plain text. `names` (optional) must all be among the objectNames
        // of the Texts found or of their parents, which pins the surface and not just a count.
        function expectPlain(root, needle, minimum, label, names) {
            tryVerify(() => tc.textsWith(root, needle).length >= minimum, 3000,
                      label + ": fewer than " + minimum + " Text show the string (found " + tc.textsWith(root, needle).length + ")")
            const found = tc.textsWith(root, needle)
            for (const item of found)
                compare(item.textFormat, Text.PlainText, label + ": " + describe(item) + " draws outside text as markup")
            if (names) {
                for (const name of names) {
                    verify(found.some(t => t.objectName === name || (t.parent && t.parent.objectName === name)),
                           label + ": no Text of " + name + " shows the string; found " + found.map(describe).join(", "))
                }
            }
        }

        function openSettings() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus, 2000, "category list has focus")
        }

        function renameBoth() {
            Profiles.renameProfile("p1", "1234", "p1", tc.hostileProfile)
            Profiles.renameProfile("p1", "1234", "p2", tc.hostileProfile + "!")
            tryVerify(() => Profiles.profiles.filter(p => p.name.indexOf(tc.hostileProfile) === 0).length === 2)
        }

        // --- profile names: the status bar, Settings -> Profiles, the picker and the PIN pad ---

        function test_profile_name_in_the_status_bar_and_the_profiles_pane() {
            renameBoth()
            expectPlain(tc.shell, tc.hostileProfile, 1, "status bar", ["activeProfileName"])
            openSettings()
            expectPlain(find("paneMyProfile"), tc.hostileProfile, 2, "Settings -> My profile")
        }

        // Manage profiles (an admin's): the list and the Rename / Delete rows of the selected profile.
        function test_profile_name_in_the_manage_profiles_pane() {
            renameBoth()
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            openSettings()
            keyClick(Qt.Key_Down)                        // Manage profiles
            tryVerify(() => find("paneProfiles").visible, 2000, "the Manage profiles pane shows")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneProfiles").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("profileRow_p2").activeFocus, 2000, "Ada's row has focus")
            keyClick(Qt.Key_Return)                      // select: Rename and Delete name the profile
            tryVerify(() => find("rowDelete").visible, 2000)
            expectPlain(find("paneProfiles"), tc.hostileProfile, 4, "Settings -> Manage profiles")
        }

        function test_profile_name_on_the_picker_and_the_pin_pad() {
            renameBoth()
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has focus")
            expectPlain(find("profileList"), tc.hostileProfile, 2, "profile picker")
            expectPlain(tc.shell, tc.hostileProfile, 2, "profile cards")
            keyClick(Qt.Key_Left)                        // Player One has a PIN
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad") !== null && find("pinPad").visible, 2000, "the PIN pad opens")
            // The title cuts a long name inside itself (T-312): the start of the markup is what is left to find.
            expectPlain(tc.shell, "Enter PIN for <b>x</b>", 1, "PIN pad")
        }

        // The profile picker and the status bar with the hostile names, for the screenshot review (`shots`).
        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            renameBoth()
            tryCompare(find("activeProfileName"), "text", tc.hostileProfile + "!")
            wait(400)
            grabImage(tc.shell).save(shotsDir + "/72-plain-text-home-status.png")
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has focus")
            wait(700)
            grabImage(tc.shell).save(shotsDir + "/72-plain-text-profile-picker.png")
        }

        // --- Bluetooth: a paired device in Settings, a pad's toast ---

        function test_bluetooth_device_name() {
            Bluetooth.mockSetName("bt-pad-old", tc.hostile)
            Bluetooth.mockGamepad(true, "usb-7", tc.hostile, "", "usb")
            tryVerify(() => find("toastText") !== null && textsWith(find("toastText"), tc.hostile).length > 0, 4000, "the pad's toast")
            expectPlain(tc.shell, tc.hostile, 1, "pad toast", ["toastText"])
            openSettings()
            tryVerify(() => find("btDev_bt-pad-old") !== null, 3000, "the device row")
            expectPlain(find("btDev_bt-pad-old"), tc.hostile, 1, "Bluetooth device row", ["label"])
        }

        // The confirmation that names the device: its title, and the confirm button's label ("Forget <name>").
        function test_forget_confirmation_names_the_device() {
            Bluetooth.mockSetName("bt-pad-old", tc.hostile)
            openSettings()
            keyClick(Qt.Key_Down)                        // Network
            keyClick(Qt.Key_Down)                        // Bluetooth & controllers
            keyClick(Qt.Key_Right)
            tryVerify(() => find("btForget_bt-pad-old") !== null, 3000, "the Forget row")
            find("btForget_bt-pad-old").forceActiveFocus()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("btForgetConfirm").shown, 2000, "the confirmation opens")
            expectPlain(find("btForgetConfirm"), "Forget " + tc.hostile, 2, "Forget confirmation", ["powerConfirmLabel", "powerConfirmTitle"])
        }

        // --- storage: a volume's label in Settings -> Storage and in the "drive connected" toast ---

        function test_volume_label() {
            Storage.mockSetLabel("vol-internal", tc.hostile)
            Storage.mockSetLabel("vol-stick", tc.hostile)
            Storage.mockPlugStick()
            tryVerify(() => Storage.volumes.some(v => v.id === "vol-stick"), 3000)
            openSettings()
            tryVerify(() => find("paneStorage") !== null)
            expectPlain(find("paneStorage"), tc.hostile, 2, "Settings -> Storage", ["label"])
            tryVerify(() => Notifications.model.count > 0, 4000, "a toast announces the stick")
            let toast = ""
            for (let i = 0; i < Notifications.model.count; ++i) {
                if (Notifications.model.get(i).text.indexOf(tc.hostile) >= 0)
                    toast = Notifications.model.get(i).text
            }
            verify(toast.length > 0, "the toast carries the label")
            tryVerify(() => textsWith(find("toastList"), tc.hostile).length > 0, 3000, "the toast is on screen")
            expectPlain(tc.shell, tc.hostile, 1, "drive toast", ["toastText"])
        }

        // --- network: the SSID in the pane's rows and the status row ---

        function test_wifi_name() {
            Network.mockSetSsid("wifi-cafe", tc.hostile)
            Network.mockSetSsid("wifi-home", tc.hostile)
            tryVerify(() => Network.networks.some(n => n.ssid === tc.hostile))
            Network.connectWifi("wifi-cafe", "")         // open: joins at once
            tryVerify(() => Network.networks.some(n => n.id === "wifi-cafe" && n.active), 3000)
            Network.mockSetCable(false)                  // Wi-Fi is now the primary connection
            tryCompare(Network.primary, "name", tc.hostile)
            openSettings()
            tryVerify(() => find("paneNetwork") !== null)
            expectPlain(find("paneNetwork"), tc.hostile, 3, "Settings -> Network", ["label"])
        }

        // --- the store: a card, the detail page, the search message ---

        function openStore() {
            keyClick(Qt.Key_Up)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("storeCards_featured") && find("storeCards_featured").activeFocus, 2000,
                      "first card of Featured has focus")
        }

        function test_app_name_summary_and_developer() {
            Store.mockSetAppText("org.example.Racer", tc.hostile, tc.hostile, tc.hostile)
            tryVerify(() => Store.catalogue.some(a => a.name === tc.hostile), 3000)
            openStore()
            tryVerify(() => find("appCard_org.example.Racer") !== null, 3000, "the app's card")
            expectPlain(find("appCard_org.example.Racer"), tc.hostile, 1, "Store card")
            keyClick(Qt.Key_Return)                      // the first card of Featured is Turbo Racer
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") !== null, 2000)
            // The page title, the developer line and the description.
            expectPlain(find("page_appDetail"), tc.hostile, 3, "App detail")
        }

        // Permission ids come from the service; one the shell has no words for is shown as it is.
        function test_permission_ids_from_the_service() {
            Store.mockSetAppText("org.example.Chess", "Open Chess", "Chess.", "Community", [tc.hostile])
            tryVerify(() => Store.app("org.example.Chess").permissions.indexOf(tc.hostile) >= 0, 3000)
            tc.shell.openPage("appDetail", { appId: "org.example.Chess" })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryCompare(find("page_appDetail"), "detailsReady", true)
            expectPlain(find("page_appDetail"), tc.hostile, 2, "App detail permissions", ["detailUpdateAdds"])
        }

        function test_store_search_message() {
            openStore()
            keyClick(Qt.Key_Up)
            verify(find("storeSearch").activeFocus)
            find("storeSearchEntry").accepted(tc.hostile)
            tryVerify(() => find("storeNoResults") !== null && find("storeNoResults").visible, 3000, "no result for the query")
            expectPlain(find("storeNoResults"), tc.hostile, 1, "Store search message")
        }

        // --- services' own text: a toast, and the controls that show device, sound-theme and wallpaper names ---

        function test_toast_text_from_a_service() {
            Notifications.show(tc.hostile, "info")
            tryVerify(() => find("toastText") !== null && textsWith(find("toastText"), tc.hostile).length > 0, 3000, "the toast")
            expectPlain(tc.shell, tc.hostile, 1, "toast", ["toastText"])
        }

        // The audio outputs, the sound themes (the choice row and the drive rows) and the wallpaper row are
        // SettingRow / ChoiceRow / ToggleRow: the shared controls draw a label, a value and a choice as text.
        function test_row_controls_draw_labels_and_values_as_text() {
            const rows = createTemporaryObject(rowsComponent, host)
            verify(rows)
            expectPlain(rows, tc.hostile, 5, "row controls")
            const row = findChild(rows, "plainRow")
            compare(findChild(row, "label").textFormat, Text.PlainText)
            compare(findChild(row, "value").textFormat, Text.PlainText)
            compare(findChild(findChild(rows, "plainChoice"), "label").textFormat, Text.PlainText)
        }
    }
}
