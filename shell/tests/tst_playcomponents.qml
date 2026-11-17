import QtQuick
import QtTest
import RuyaShell

// The .play components (04 §5.4, RUY-802): the trust words and badge, the trust row, the signer sheet, the
// permission list and the trailer in the screenshot viewer. They are built alone, at the size a real caller
// sets (the shell's 1920 x 1080 design size scaled to this window, u = 2/3), not through a page: the pages
// are RUY-98. The trailer plays an audio file from the repo (no video codec is needed to test the player's
// state, the position and the keys).
Item {
    id: host
    width: 1280
    height: 720

    readonly property real u: width / 1920
    readonly property string key32: "0123456789abcdef0123456789abcdef"
    readonly property url sound: Qt.resolvedUrl("../sounds/dreamglass/ambient.flac")

    ModalLayer {
        id: modal
        anchors.fill: parent
        z: 10
    }

    Component {
        id: rowComponent
        TrustRow { u: host.u }
    }
    Component {
        id: sheetComponent
        SignerSheet { u: host.u; anchors.fill: parent }
    }
    Component {
        id: listComponent
        PermissionList { u: host.u; width: 900 * host.u }
    }
    Component {
        id: shotsComponent
        ScreenshotRow {
            u: host.u
            width: 1728 * host.u
            overlay: modal
            shots: [{ image: "", thumb: "", caption: "one" }, { image: "", thumb: "", caption: "two" }]
        }
    }

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "PlayComponents"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            modal.covered = false
        }

        function cleanup() {
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
            modal.covered = false
        }

        function record(over) {
            return Object.assign({ tier: "unverified", verdict: "ok", revoked: false, signerName: "", signerKeyId: "",
                                   keyState: "", revokedReason: "" }, over)
        }
        function official() { return record({ tier: "official", signerName: "Pixel Forest", signerKeyId: host.key32, keyState: "same" }) }
        function developer() { return record({ tier: "developer", signerName: "Pixel Forest", signerKeyId: host.key32, keyState: "new" }) }

        // ---- the trust words (one place) ----

        function test_trust_states_data() {
            return [
                { tag: "official", info: official(), state: "official", kind: "success", badge: "Official", icon: "check_circle",
                  line: "Signed by Pixel Forest and the RuyaOS store", sheet: true,
                  trBadge: "Resmi", trLine: "Pixel Forest ve RuyaOS mağazası imzalı" },
                { tag: "developer", info: developer(), state: "developer", kind: "warning", badge: "Developer", icon: "info",
                  line: "Signed by Pixel Forest · key 0123…cdef", sheet: true,
                  trBadge: "Geliştirici", trLine: "Pixel Forest imzalı · anahtar 0123…cdef" },
                { tag: "developer-no-name", info: record({ tier: "developer", signerKeyId: host.key32 }), state: "developer", kind: "warning",
                  badge: "Developer", icon: "info", line: "Signed by key 0123…cdef", sheet: true,
                  trBadge: "Geliştirici", trLine: "anahtar 0123…cdef imzalı" },
                { tag: "unverified", info: record({}), state: "unverified", kind: "error", badge: "Unverified", icon: "warning",
                  line: "Not signed. Anyone could have changed it.", sheet: true,
                  trBadge: "Doğrulanmamış", trLine: "İmzasız. Herhangi biri değiştirmiş olabilir." },
                { tag: "changed", info: record({ tier: "developer", verdict: "bad-signature", signerName: "Pixel Forest", signerKeyId: host.key32 }),
                  state: "changed", kind: "error", badge: "Changed since signed", icon: "error",
                  line: "This package was changed after it was signed.", sheet: false,
                  trBadge: "İmzadan sonra değişmiş", trLine: "Bu paket imzalandıktan sonra değiştirilmiş." },
                { tag: "revoked", info: record({ tier: "official", revoked: true, revokedReason: "stole saves", signerName: "Pixel Forest", signerKeyId: host.key32 }),
                  state: "revoked", kind: "error", badge: "Removed for safety", icon: "error",
                  line: "Removed for safety: stole saves", sheet: false,
                  trBadge: "Güvenlik için kaldırıldı", trLine: "Güvenlik için kaldırıldı: stole saves" },
                // The precedence: revoked over a bad signature over the tier.
                { tag: "revoked-and-changed", info: record({ tier: "official", revoked: true, verdict: "bad-signature", revokedReason: "x" }),
                  state: "revoked", kind: "error", badge: "Removed for safety", icon: "error",
                  line: "Removed for safety: x", sheet: false,
                  trBadge: "Güvenlik için kaldırıldı", trLine: "Güvenlik için kaldırıldı: x" },
                { tag: "changed-over-official", info: record({ tier: "official", verdict: "bad-signature" }),
                  state: "changed", kind: "error", badge: "Changed since signed", icon: "error",
                  line: "This package was changed after it was signed.", sheet: false,
                  trBadge: "İmzadan sonra değişmiş", trLine: "Bu paket imzalandıktan sonra değiştirilmiş." }
            ]
        }
        function test_trust_states(data) {
            let t = PlayTrust.describe(data.info)
            compare(t.state, data.state)
            compare(t.kind, data.kind)
            compare(t.badge, data.badge)
            compare(t.icon, data.icon)
            compare(t.line, data.line)
            compare(t.opensSheet, data.sheet)
            compare(t.solid, true)
            DeviceSettings.language = "tr"
            t = PlayTrust.describe(data.info)
            compare(t.badge, data.trBadge)
            compare(t.line, data.trLine)
        }

        function test_the_short_key_and_the_groups() {
            compare(PlayTrust.shortKey(host.key32), "0123…cdef")
            verify(PlayTrust.shortKey(host.key32).indexOf("...") < 0, "one ellipsis character, not three dots")
            compare(PlayTrust.shortKey(host.key32).charCodeAt(4), 0x2026)
            compare(PlayTrust.shortKey(""), "")
            compare(PlayTrust.groupedKey(host.key32), "0123 4567 89ab cdef 0123 4567 89ab cdef")
            compare(PlayTrust.groupedKey(host.key32).split(" ").length, 8)
            compare(PlayTrust.clock(65), "1:05")
            compare(PlayTrust.clock(0), "0:00")
        }

        function test_badge_error_kind() {
            const badge = createTemporaryObject(badgeComponent, host)
            compare(badge.tone, Theme.toastError)
            compare(badge.color.a, Theme.badgeFillAlpha)
            compare(badge.border.width, 0)
            badge.solid = true
            compare(badge.color, Theme.toastBackground)
        }
        Component {
            id: badgeComponent
            Badge { kind: "error"; text: "Unverified" }
        }

        // ---- contrast of the trust badges (04 §7: 4.5:1), computed, on all five themes ----

        // A trust badge is always `solid` (04 5.4): its own `toastBackground` (94 % alpha) over whatever is behind.
        // The text is the kind colour; held to 4.5:1 over the ground, the panel and glass over each backdrop
        // sample, for success, warning and error, on every theme.
        function badgeRows(t) {
            const rows = []
            const samples = ThemeMath.backdropSamples(t, t.defaultTint)
            const grounds = [["background", t.background], ["panel", t.panel]]
            for (let i = 0; i < samples.strict.length; ++i)
                grounds.push(["glass over backdrop sample " + i, ThemeMath.over(t.glass, samples.strict[i])])
            for (const kind of ["toastSuccess", "toastWarning", "toastError"]) {
                for (const g of grounds)
                    rows.push({ label: kind + " on " + g[0], ratio: ThemeMath.contrast(t[kind], ThemeMath.over(t.toastBackground, g[1])), min: 4.5 })
            }
            return rows
        }
        function test_trust_badge_contrast_data() {
            return Themes.all.map(s => ({ tag: s.key, key: s.key }))
        }
        function test_trust_badge_contrast(data) {
            const rows = badgeRows(Themes.snapshot(Themes.byKey(data.key)))
            const bad = rows.filter(r => r.ratio < r.min).map(r => r.label + ": " + r.ratio.toFixed(2) + " < " + r.min)
            verify(bad.length === 0, data.key + " fails: " + bad.join("; "))
            verify(rows.length === 3 * 6, "every row was measured")
        }

        function test_every_trust_badge_is_solid() {
            for (const d of test_trust_states_data()) {
                const t = PlayTrust.describe(d.info)
                compare(t.solid, true, d.tag)
            }
            const o = openSheet(developer())
            compare(findChild(o.sheet, "signerBadge").solid, true)
        }

        // ---- the trust row ----

        function test_the_row_takes_focus_only_when_it_opens_the_sheet_data() {
            return [
                { tag: "official", info: official(), focusable: true },
                { tag: "developer", info: developer(), focusable: true },
                { tag: "unverified", info: record({}), focusable: true },
                { tag: "changed", info: record({ verdict: "bad-signature" }), focusable: false },
                { tag: "revoked", info: record({ revoked: true }), focusable: false }
            ]
        }
        function test_the_row_takes_focus_only_when_it_opens_the_sheet(data) {
            const row = createTemporaryObject(rowComponent, host, { info: data.info })
            row.forceActiveFocus()
            compare(row.activeFocus, data.focusable)
            compare(findChild(row, "trustChevron").visible, data.focusable)
            compare(row.height, Theme.rowHeight * host.u)
            verify(row.width <= 960 * host.u + 0.5)
            let opened = 0
            row.activated.connect(() => { ++opened })
            if (data.focusable) {
                keyClick(Qt.Key_Return)
                compare(opened, 1)
            }
        }

        function test_the_row_shows_the_line_and_the_icon_colour() {
            const row = createTemporaryObject(rowComponent, host, { info: record({ verdict: "bad-signature" }) })
            compare(findChild(row, "trustLine").text, "This package was changed after it was signed.")
            compare(findChild(row, "trustLine").color, Theme.errorText)
            compare(findChild(row, "trustIcon").color, Theme.errorText)
            row.info = official()
            compare(findChild(row, "trustLine").color, Theme.text)
            compare(findChild(row, "trustIcon").name, "check_circle")
            row.info = record({})
            compare(findChild(row, "trustIcon").color, Theme.errorText, "unverified: the icon is errorText")
            compare(findChild(row, "trustLine").color, Theme.text, "unverified: the line is not")
        }

        function test_a_long_line_stops_at_960() {
            const row = createTemporaryObject(rowComponent, host, {
                info: record({ tier: "developer", signerName: "A very long developer name that goes on and on and on and on and on and on", signerKeyId: host.key32 }) })
            verify(row.width <= 960 * host.u + 0.5, "width " + row.width)
            verify(findChild(row, "trustLine").truncated)
        }

        // ---- the signer sheet ----

        function openSheet(info) {
            const row = createTemporaryObject(rowComponent, host, { info: info })
            const sheet = createTemporaryObject(sheetComponent, modal)
            row.activated.connect(() => sheet.open(row.info, row))
            row.forceActiveFocus()
            verify(row.activeFocus)
            keyClick(Qt.Key_Return)
            verify(sheet.shown)
            tryVerify(() => findChild(sheet, "signerClose").activeFocus)
            tryCompare(sheet, "opacity", 1)                   // faded in: the rows' effective visibility is real
            return { row: row, sheet: sheet }
        }

        function test_the_sheet_opens_and_closes_by_controller_and_gives_the_focus_back() {
            const o = openSheet(developer())
            compare(findChild(o.sheet, "signerTitle").text, "Who signed this")
            compare(o.sheet.modalHints.length, 1)
            compare(o.sheet.modalHints[0].action, "back")
            keyClick(Qt.Key_Escape)
            verify(!o.sheet.shown)
            verify(o.row.activeFocus, "the trust row has the focus again")
            // Accept on Close closes too.
            keyClick(Qt.Key_Return)
            verify(o.sheet.shown)
            keyClick(Qt.Key_Return)
            verify(!o.sheet.shown)
            verify(o.row.activeFocus)
        }

        function test_the_sheet_rows_follow_key_state_and_the_tier_data() {
            return [
                { tag: "official-same", info: official(), seen: "Yes, the same key as the installed game", err: false,
                  note: "The developer and the RuyaOS store both signed every file.", badge: "Official",
                  trSeen: "Evet, kurulu oyunla aynı anahtar", trNote: "Her dosyayı hem geliştirici hem RuyaOS mağazası imzaladı." },
                { tag: "developer-new", info: developer(), seen: "No, a new key", err: false,
                  note: "A signature shows that this key signed every file. It doesn't prove who the developer is.", badge: "Developer",
                  trSeen: "Hayır, yeni bir anahtar", trNote: "İmza, her dosyayı bu anahtarın imzaladığını gösterir. Geliştiricinin kim olduğunu kanıtlamaz." },
                { tag: "developer-different",
                  info: record({ tier: "developer", signerName: "Pixel Forest", signerKeyId: host.key32, keyState: "different" }),
                  seen: "No, a different key", err: true,
                  note: "A signature shows that this key signed every file. It doesn't prove who the developer is.", badge: "Developer",
                  trSeen: "Hayır, farklı bir anahtar", trNote: "İmza, her dosyayı bu anahtarın imzaladığını gösterir. Geliştiricinin kim olduğunu kanıtlamaz." }
            ]
        }
        function test_the_sheet_rows_follow_key_state_and_the_tier(data) {
            const o = openSheet(data.info)
            const seen = findChild(findChild(o.sheet, "signerRowSeen"), "signerValue")
            compare(seen.text, data.seen)
            compare(seen.color, data.err ? Theme.errorText : Theme.text)
            compare(findChild(o.sheet, "signerNote").text, data.note)
            compare(findChild(o.sheet, "signerBadge").text, data.badge)
            compare(findChild(findChild(o.sheet, "signerRowName"), "signerValue").text, "Pixel Forest")
            DeviceSettings.language = "tr"
            compare(seen.text, data.trSeen)
            compare(findChild(o.sheet, "signerNote").text, data.trNote)
            compare(findChild(o.sheet, "signerTitle").text, "Kim imzaladı")
            // The Turkish labels are not clipped by the key column.
            for (const name of ["signerRowName", "signerRowSeen", "signerRowTrust"]) {
                const label = findChild(o.sheet, name).children.find(c => c.font && c.font.weight === Theme.weightDemiBold)
                verify(label && !label.truncated, name + " label is whole")
            }
        }

        function test_the_key_is_in_eight_groups_of_four() {
            const o = openSheet(developer())
            const key = findChild(findChild(o.sheet, "signerRowKey"), "signerValue")
            compare(key.text, "0123 4567 89ab cdef 0123 4567 89ab cdef")
            compare(key.text.split(" ").length, 8)
            verify(key.text.split(" ").every(g => g.length === 4))
        }

        function test_the_trust_row_has_its_label_and_the_badge_in_the_value_column() {
            const o = openSheet(developer())
            const trustRow = findChild(o.sheet, "signerRowTrust")
            const badge = findChild(o.sheet, "signerBadge")
            const at = badge.mapToItem(trustRow, 0, 0)
            verify(at.x >= (Theme.spaceL + 300) * host.u - 1, "the badge starts in the value column: " + at.x)
            verify(at.y >= 0 && at.y + badge.height <= trustRow.height, "inside the row")
            compare(badge.solid, true)
        }

        function test_signed_by_is_hidden_without_a_name_and_an_unsigned_package_has_no_key() {
            const named = openSheet(developer())
            verify(findChild(named.sheet, "signerRowName").visible)
            keyClick(Qt.Key_Escape)
            const anon = openSheet(record({ tier: "developer", signerKeyId: host.key32, keyState: "new" }))
            verify(!findChild(anon.sheet, "signerRowName").visible, "no name: no row, never 'Unknown'")
            verify(findChild(anon.sheet, "signerRowKey").visible)
            keyClick(Qt.Key_Escape)
            const unsigned = openSheet(record({}))
            verify(!findChild(unsigned.sheet, "signerRowName").visible)
            verify(!findChild(unsigned.sheet, "signerRowKey").visible)
            verify(!findChild(unsigned.sheet, "signerRowSeen").visible)
            compare(findChild(unsigned.sheet, "signerBadge").text, "Unverified")
            compare(findChild(unsigned.sheet, "signerNote").text, "Nobody signed this package, so nothing shows who made it or whether it was changed.")
        }

        function test_the_sheet_is_1100_wide_and_inside_the_screen() {
            const o = openSheet(official())
            const card = findChild(o.sheet, "signerSheet")
            compare(card.width, 1100 * host.u)
            verify(card.height > 0 && card.height <= host.height, "height " + card.height)
            verify(card.x >= 0 && card.x + card.width <= host.width)
        }

        // ---- held keys: an auto-repeat press changes nothing ----

        function fakeKey(key, repeat) { return { key: key, isAutoRepeat: repeat, accepted: false } }

        function test_a_held_key_does_nothing_more() {
            const r = row({})
            const v = openTrailer(r)
            const box = v.trailerPlayer
            const sounds = Sfx.selectCount
            const ev = fakeKey(Qt.Key_Return, true)
            v.handleKey(ev)
            compare(box.wantsPlay, true, "a repeat does not pause")
            compare(Sfx.selectCount, sounds)
            verify(ev.accepted, "still a modal: the key is taken")
            v.handleKey(fakeKey(Qt.Key_Return, false))
            compare(box.wantsPlay, false, "the first press does")
            v.handleKey(fakeKey(Qt.Key_Return, true))
            compare(box.wantsPlay, false)
            const back = fakeKey(Qt.Key_Escape, true)
            v.handleKey(back)
            // Back on the viewer is a single press as before (closing twice is harmless), so only the toggle is guarded.
            verify(back.accepted)
        }

        function test_a_held_accept_does_not_open_the_sheet_twice() {
            const row2 = createTemporaryObject(rowComponent, host, { info: developer() })
            let opened = 0
            row2.activated.connect(() => { ++opened })
            const ev = fakeKey(Qt.Key_Return, true)
            row2.accept(ev)
            compare(opened, 0)
            verify(ev.accepted, "taken, not passed on")
            row2.accept(fakeKey(Qt.Key_Return, false))
            compare(opened, 1)
        }

        function test_a_held_back_does_not_close_the_sheet() {
            const o = openSheet(developer())
            const ev = fakeKey(Qt.Key_Escape, true)
            o.sheet.handleKey(ev)
            verify(o.sheet.shown, "a repeat of B closes nothing")
            verify(ev.accepted)
            o.sheet.handleKey(fakeKey(Qt.Key_Escape, false))
            verify(!o.sheet.shown)
        }

        // ---- the permission list ----

        function entries() {
            return [
                { key: "network", words: "Uses the network", risk: "medium", reason: "Leaderboards" },
                { key: "input:all-devices", words: "Accesses all devices", risk: "high", reason: "" },
                { key: "mystery", words: "Does a thing the shell has no words for", risk: "low", reason: "" }
            ]
        }
        function wordsOf(list, key) { return findChild(findChild(list, "permission_" + key), "permissionWords") }

        function test_words_follow_the_key_in_en_and_tr() {
            const list = createTemporaryObject(listComponent, host, { entries: entries(), always: true })
            compare(wordsOf(list, "always").text, "Plays sound, uses graphics")
            compare(wordsOf(list, "network").text, "Uses the network")
            compare(wordsOf(list, "input:all-devices").text, "Accesses all devices")
            compare(wordsOf(list, "mystery").text, "Does a thing the shell has no words for", "the service's words only for an unknown key")
            DeviceSettings.language = "tr"
            compare(wordsOf(list, "always").text, "Ses çalar, grafik kullanır")
            compare(wordsOf(list, "network").text, "Ağı kullanır")
            compare(wordsOf(list, "input:all-devices").text, "Tüm aygıtlara erişir")
            compare(wordsOf(list, "mystery").text, "Does a thing the shell has no words for")
        }

        function test_the_words_table_data() {
            return [
                { key: "input:controllers", en: "Uses controllers", tr: "Kontrolcüleri kullanır" },
                { key: "input:controllers+keyboard-mouse", en: "Uses controllers, keyboard and mouse", tr: "Kontrolcü, klavye ve fare kullanır" },
                { key: "removable_media:read", en: "Reads files on USB drives", tr: "USB bellekteki dosyaları okur" },
                { key: "removable_media:write", en: "Changes files on USB drives", tr: "USB bellekteki dosyaları değiştirir" },
                { key: "multiarch", en: "Runs 32-bit programs", tr: "32 bit programlar çalıştırır" },
                { key: "gamemode", en: "Asks the system to prioritise it", tr: "Sistemden öncelik ister" },
                { key: "realtime", en: "Asks the system to prioritise it", tr: "Sistemden öncelik ister" },
                { key: "devel", en: "Can inspect other programs", tr: "Diğer programları inceleyebilir" }
            ]
        }
        function test_the_words_table(data) {
            compare(PlayTrust.permissionWords(data.key, "service"), data.en)
            DeviceSettings.language = "tr"
            compare(PlayTrust.permissionWords(data.key, "service"), data.tr)
        }

        function test_the_reason_line_shows_in_curly_quotes_and_elides() {
            const list = createTemporaryObject(listComponent, host, { entries: entries() })
            const reason = findChild(list, "permissionReason_network")
            verify(reason.visible)
            compare(reason.text, "“Leaderboards”")
            compare(reason.font.pixelSize, Theme.typeCaption * host.u)
            verify(!findChild(list, "permissionReason_mystery").visible, "no reason, no line")
            verify(reason.y > wordsOf(list, "network").y, "under the words")
            list.entries = [{ key: "network", words: "", risk: "low",
                              reason: "A very long reason that the developer wrote to explain why the game needs the network and then went on" }]
            verify(findChild(list, "permissionReason_network").truncated, "elided")
            verify(findChild(list, "permissionReason_network").width <= 900 * host.u)
            // Plain text: markup stays as typed.
            list.entries = [{ key: "network", words: "", risk: "low", reason: "<b>bold</b>" }]
            compare(findChild(list, "permissionReason_network").text, "“<b>bold</b>”")
            compare(findChild(list, "permissionReason_network").textFormat, Text.PlainText)
        }

        function test_the_high_risk_badge_follows_the_risk() {
            const list = createTemporaryObject(listComponent, host, { entries: entries() })
            verify(findChild(list, "riskFlag_input:all-devices").visible)
            compare(findChild(list, "riskFlag_input:all-devices").kind, "warning")
            compare(wordsOf(list, "input:all-devices").color, Theme.warningText)
            verify(!findChild(list, "riskFlag_network").visible)
            compare(wordsOf(list, "network").color, Theme.text)
        }

        function test_and_n_more_past_max_rows() {
            const list = createTemporaryObject(listComponent, host, { entries: entries(), always: true, maxRows: 2 })
            compare(list.shownCount, 2)
            verify(findChild(list, "permission_always"))
            verify(findChild(list, "permission_network"))
            verify(!findChild(list, "permission_mystery"), "cut")
            verify(findChild(list, "permissionMore").visible)
            compare(findChild(list, "permissionMore").text, "And 2 more")
            DeviceSettings.language = "tr"
            compare(findChild(list, "permissionMore").text, "Ve 2 tane daha")
            DeviceSettings.language = "en"
            list.maxRows = 0
            verify(!findChild(list, "permissionMore").visible)
            list.maxRows = 4
            verify(!findChild(list, "permissionMore").visible, "everything fits")
            list.maxRows = 3
            compare(findChild(list, "permissionMore").text, "And 1 more")
        }

        // ---- the trailer ----

        function trailer(over) {
            return Object.assign({ video: host.sound.toString(), poster: "", name: "Launch trailer", seconds: 65 }, over)
        }
        function row(over) {
            const r = createTemporaryObject(shotsComponent, host, Object.assign({ trailer: trailer({}) }, over))
            verify(r)
            return r
        }
        function toStrip(r) {
            r.strip.forceActiveFocus()
            verify(r.strip.activeFocus)
        }
        function openTrailer(r) {
            toStrip(r)
            keyClick(Qt.Key_Return)
            tryVerify(() => r.viewer && r.viewer.shown && r.viewer.activeFocus, 2000)
            compare(r.viewer.trailerMode, true)
            return r.viewer
        }

        function test_the_trailer_card_is_first() {
            const r = row({})
            compare(r.cards, 3)
            compare(findChild(r, "screenshotsHeading").text, "Screenshots and trailer")
            verify(findChild(r, "screenshotCard_0"))
            verify(findChild(r, "screenshotCard_2"))
            verify(!findChild(r, "screenshotCard_3"))
            verify(findChild(findChild(r, "screenshotCard_0"), "trailerPlay").visible)
            verify(!findChild(findChild(r, "screenshotCard_1"), "trailerPlay").visible)
            compare(findChild(findChild(r, "screenshotCard_0"), "trailerCaption").text, "Trailer · 1:05")
            const play = findChild(findChild(r, "screenshotCard_0"), "trailerPlay")
            compare(play.width, 88 * host.u)
            DeviceSettings.language = "tr"
            compare(findChild(findChild(r, "screenshotCard_0"), "trailerCaption").text, "Fragman · 1:05")
            compare(findChild(r, "screenshotsHeading").text, "Ekran görüntüleri ve fragman")
        }

        function test_without_a_trailer_the_row_is_as_before() {
            const r = createTemporaryObject(shotsComponent, host)
            compare(r.cards, 2)
            compare(findChild(r, "screenshotsHeading").text, "Screenshots")
            verify(!findChild(findChild(r, "screenshotCard_0"), "trailerPlay").visible)
        }

        function test_accept_on_the_trailer_card_opens_the_viewer_in_trailer_mode() {
            const r = row({})
            const v = openTrailer(r)
            compare(findChild(v, "viewerTrailerName").text, "Launch trailer")
            verify(!findChild(v, "viewerCounter").visible)
            compare(v.modalHints.length, 3)
            compare(v.modalHints[0].text, "Pause")
            const box = findChild(v, "trailerPlayer")
            compare(box.width, v.boxWidth)
            compare(box.height, v.boxHeight)
            compare(box.x, v.boxX)
            tryCompare(box.player, "playbackState", 1)       // MediaPlayer.PlayingState
        }

        function test_a_toggles_play_and_pause() {
            const r = row({})
            const v = openTrailer(r)
            const player = v.trailerPlayer.player
            tryCompare(player, "playbackState", 1)
            keyClick(Qt.Key_Return)
            tryCompare(player, "playbackState", 2)           // PausedState
            compare(v.modalHints[0].text, "Play")
            compare(findChild(v, "trailerStateIcon").name, "play_arrow")
            keyClick(Qt.Key_Return)
            tryCompare(player, "playbackState", 1)
            compare(findChild(v, "trailerStateIcon").name, "pause")
        }

        function test_left_and_right_seek_ten_seconds_and_clamp() {
            const r = row({})
            const v = openTrailer(r)
            const player = v.trailerPlayer.player
            tryCompare(player, "playbackState", 1)
            tryVerify(() => player.duration > 20000, 5000, "the file's length is known")
            keyClick(Qt.Key_Return)                           // paused: the position holds still
            tryCompare(player, "playbackState", 2)
            player.position = 0
            tryCompare(player, "position", 0)
            keyClick(Qt.Key_Right)
            tryVerify(() => Math.abs(player.position - 10000) < 400, 3000, "10 s forward: " + player.position)
            keyClick(Qt.Key_Right)
            tryVerify(() => Math.abs(player.position - 20000) < 400, 3000, "20 s: " + player.position)
            keyClick(Qt.Key_Left)
            tryVerify(() => Math.abs(player.position - 10000) < 400, 3000, "back to 10 s: " + player.position)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            tryVerify(() => player.position < 400, 3000, "clamped at the start: " + player.position)
            player.position = Math.max(0, player.duration - 3000)
            tryVerify(() => player.duration - player.position < 3500)
            keyClick(Qt.Key_Right)
            tryVerify(() => player.duration - player.position < 400, 3000, "clamped at the end: " + player.position)
        }

        function test_the_bar_hides_after_the_idle_time_and_stays_while_paused() {
            const r = row({})
            const v = openTrailer(r)
            const box = v.trailerPlayer
            const bar = findChild(v, "trailerBar")
            compare(box.barShown, true)
            compare(box.hideMs, Math.round(3000 * Theme.motionFactor), "3 s at the motion scale")
            tryCompare(box, "barShown", false, 3000)
            tryCompare(bar, "visible", false, 3000)
            keyClick(Qt.Key_Down)                              // any input
            compare(box.barShown, true)
            tryCompare(bar, "visible", true)
            keyClick(Qt.Key_Return)                            // pause: the bar stays
            tryCompare(box.player, "playbackState", 2)
            wait(box.hideMs * 4 + 100)
            compare(box.barShown, true, "it stays while paused")
            keyClick(Qt.Key_Return)                            // play: it hides again
            tryCompare(box, "barShown", false, 3000)
        }

        function test_the_bar_geometry() {
            const r = row({})
            const v = openTrailer(r)
            const bar = findChild(v, "trailerBar")
            const box = findChild(v, "trailerPlayer")
            compare(bar.height, Theme.rowHeight * host.u)
            compare(bar.x, 24 * host.u)
            compare(bar.width, box.width - 48 * host.u)
            compare(bar.y + bar.height, box.height - 24 * host.u)
            compare(findChild(v, "trailerTime").text.indexOf(" / ") > 0, true)
        }

        function test_the_hub_pauses_it() {
            const r = row({})
            const v = openTrailer(r)
            const player = v.trailerPlayer.player
            tryCompare(player, "playbackState", 1)
            modal.covered = true                               // the Hub (or Who's playing?) opened
            tryCompare(player, "playbackState", 2)
            modal.covered = false
            tryCompare(player, "playbackState", 1, 3000, "it goes on when the Hub closes")
            keyClick(Qt.Key_Return)                            // paused by the player
            tryCompare(player, "playbackState", 2)
            modal.covered = true
            modal.covered = false
            wait(100)
            compare(player.playbackState, 2, "the Hub does not start what the player paused")
        }

        function test_back_returns_the_focus_to_the_trailer_card() {
            const r = row({})
            const v = openTrailer(r)
            const player = v.trailerPlayer.player
            keyClick(Qt.Key_Escape)
            tryVerify(() => !v.shown)
            verify(r.strip.activeFocus, "the row has the focus")
            compare(r.strip.currentIndex, 0, "on the trailer card")
            tryCompare(player, "playbackState", 0)             // StoppedState: it never plays on its own
            // From the second picture, Back returns to that picture's card.
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => v.shown && !v.trailerMode)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !v.shown)
            compare(r.strip.currentIndex, 1)
        }

        function test_the_page_does_not_play_on_its_own() {
            const r = row({})
            toStrip(r)
            wait(100)
            verify(!r.viewer || !r.viewer.shown)
            verify(!r.viewer || r.viewer.trailerPlayer.player.playbackState === 0)
        }

        function test_an_unplayable_source_shows_the_line_data() {
            return [{ tag: "no source", video: "" }, { tag: "missing file", video: "/nonexistent/trailer.mp4" }]
        }
        function test_an_unplayable_source_shows_the_line(data) {
            const r = row({ trailer: trailer({ video: data.video }) })
            const v = openTrailer(r)
            const failed = findChild(v, "trailerFailed")
            tryVerify(() => failed.visible, 5000)
            compare(findChild(v, "trailerFailedText").text, "The trailer can't play.")
            tryVerify(() => !findChild(v, "trailerBar").visible, 2000, "no bar to play with")
            DeviceSettings.language = "tr"
            compare(findChild(v, "trailerFailedText").text, "Fragman oynatılamıyor.")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !v.shown)
            verify(r.strip.activeFocus)
        }

        // The Shell sets ModalLayer.covered while the Hub is open; a trailer in a viewer on that layer pauses.
        function test_the_shell_pauses_the_trailer_when_the_hub_opens() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            const shell = createTemporaryObject(shellComponent, host)
            verify(shell)
            shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => findChild(shell, "profileList").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => findChild(shell, "homePlay").activeFocus, 2000)
            const layer = findChild(shell, "modalLayer")
            compare(layer.covered, false)
            const r = createTemporaryObject(shotsComponent, shell, { overlay: layer, trailer: trailer({}) })
            const v = openTrailer(r)
            const player = v.trailerPlayer.player
            tryCompare(player, "playbackState", 1)
            shell.guideDown(false)                             // the controller's Guide button (the viewer takes the key itself)
            tryVerify(() => findChild(shell, "systemActions").activeFocus, 2000, "the Hub opens")
            compare(layer.covered, true)
            tryCompare(player, "playbackState", 2)
            keyClick(Qt.Key_Escape)                            // B closes the Hub
            tryVerify(() => !findChild(shell, "systemActions").activeFocus, 2000)
            tryCompare(layer, "covered", false)
            tryCompare(player, "playbackState", 1, 3000, "it goes on when the Hub closes")
        }

        // ---- screenshots (dev.ps1 shots) ----

        Component {
            id: stageComponent
            Item {
                id: stage
                width: host.width
                height: host.height
                property alias row: stageRow
                property alias list: stageList
                property alias sheet: stageSheet
                Backdrop { id: bg; anchors.fill: parent }
                ModalLayer {
                    id: stageModal
                    anchors.fill: parent
                    glassSource: bg
                    z: 5
                    SignerSheet {
                        id: stageSheet
                        u: host.u
                        anchors.fill: parent
                    }
                }
                TrustRow {
                    id: stageRow
                    u: host.u
                    x: 96 * host.u
                    y: 96 * host.u
                    info: tc.developer()
                }
                PermissionList {
                    id: stageList
                    u: host.u
                    x: 96 * host.u
                    y: 260 * host.u
                    width: 1100 * host.u
                    always: true
                    entries: [
                        { key: "input:controllers", words: "Uses controllers", risk: "low", reason: "" },
                        { key: "network", words: "Uses the network", risk: "medium", reason: "Cloud saves and the leaderboard" },
                        { key: "input:all-devices", words: "Accesses all devices", risk: "high", reason: "Reads the racing wheel and the pedals" },
                        { key: "removable_media:write", words: "Changes files on USB drives", risk: "medium", reason: "" }
                    ]
                }
            }
        }

        function settle() {
            wait(600)
            grabImage(tc.stage)
            wait(300)
        }
        property var stage: null

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUY_SHOTS_DIR to save screenshots")
            DeviceSettings.reducedMotion = true
            tc.stage = createTemporaryObject(stageComponent, host)
            verify(tc.stage)
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                tc.stage.row.info = developer()
                tc.stage.row.forceActiveFocus()
                settle()
                grabImage(tc.stage).save(shotsDir + "/96-play-" + "trust-row-focused-" + lang + ".png")
                tc.stage.row.info = record({ verdict: "bad-signature" })
                settle()
                grabImage(tc.stage).save(shotsDir + "/96-play-" + "trust-row-changed-" + lang + ".png")
                tc.stage.row.info = developer()
                tc.stage.row.forceActiveFocus()
                tc.stage.sheet.open(developer(), tc.stage.row)
                settle()
                grabImage(tc.stage).save(shotsDir + "/96-play-" + "signer-sheet-" + lang + ".png")
                tc.stage.sheet.close()
                settle()
                grabImage(tc.stage).save(shotsDir + "/96-play-" + "permissions-" + lang + ".png")
            }
            tc.stage.destroy()
            tc.stage = null
        }

        Component {
            id: trailerStage
            Item {
                id: tstage
                width: host.width
                height: host.height
                property alias row: trow
                Backdrop { anchors.fill: parent }
                ModalLayer { id: tmodal; anchors.fill: parent; z: 5 }
                ScreenshotRow {
                    id: trow
                    u: host.u
                    x: 96 * host.u
                    y: 300 * host.u
                    width: 1728 * host.u
                    overlay: tmodal
                    trailer: tc.trailer({})
                    shots: [{ image: "", thumb: "", caption: "one" }, { image: "", thumb: "", caption: "two" }]
                }
            }
        }

        function test_zz_screenshots_trailer() {
            if (!shotsDir)
                skip("set RUY_SHOTS_DIR to save screenshots")
            DeviceSettings.reducedMotion = true
            const ts = createTemporaryObject(trailerStage, host)
            verify(ts)
            tc.stage = ts
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                ts.row.strip.forceActiveFocus()
                settle()
                grabImage(tc.stage).save(shotsDir + "/96-play-" + "trailer-card-" + lang + ".png")
                keyClick(Qt.Key_Return)
                tryVerify(() => ts.row.viewer && ts.row.viewer.shown, 2000)
                tryVerify(() => ts.row.viewer.trailerPlayer.player.playbackState === 1, 5000)
                ts.row.viewer.trailerPlayer.wake()
                settle()
                grabImage(tc.stage).save(shotsDir + "/96-play-" + "trailer-viewer-" + lang + ".png")
                keyClick(Qt.Key_Escape)
                tryVerify(() => !ts.row.viewer.shown)
            }
            ts.destroy()
            tc.stage = null
        }
    }
}
