pragma Singleton
import QtQuick
import RuyaShell

// The words of a .play package's trust (04 §5.4, 05 §0, §9.2, RUY-802): one place that turns an Inspect
// record (`tier`, `verdict`, `revoked`, `revokedReason`, `signerName`, `signerKeyId`, `keyState`) into
// what the trust badge, the trust row and the signer sheet say. Only Official is ever "verified"; a
// signature proves "the same key signed this", never who the developer is.
//
// Every function reads `language`, so a binding that calls one is evaluated again when the UI language
// changes (as DurationText).
QtObject {
    id: root

    readonly property string language: DeviceSettings.language

    // The first 4 and last 4 hex characters joined by "…"; a short or empty id is shown as it is.
    function shortKey(keyId) {
        const id = keyId ?? ""
        return id.length > 8 ? id.slice(0, 4) + "…" + id.slice(-4) : id
    }

    // The 32-character key id in eight groups of four, separated by spaces.
    function groupedKey(keyId) {
        const id = keyId ?? ""
        const groups = []
        for (let i = 0; i < id.length; i += 4)
            groups.push(id.slice(i, i + 4))
        return groups.join(" ")
    }

    // Which state the record is in: revoked, then a bad-signature verdict, then the tier.
    function stateOf(info) {
        if (!info)
            return "unverified"
        if (info.revoked === true)
            return "revoked"
        if (info.verdict === "bad-signature")
            return "changed"
        return info.tier === "official" || info.tier === "developer" ? info.tier : "unverified"
    }

    // { state, kind, solid (always true: a trust badge is always `solid`, 04 5.4), badge, icon, iconError, line, bad, opensSheet }: `iconError` = the icon is `errorText`
    // (unverified, changed, revoked); `bad` = the line is `errorText` too (changed, revoked); `opensSheet` = Accept
    // opens the signer sheet (official, developer, unverified).
    function describe(info) {
        if (language === undefined)
            return ({})
        const state = stateOf(info)
        const name = info ? (info.signerName ?? "") : ""
        const key = shortKey(info ? info.signerKeyId : "")
        switch (state) {
        case "official":
            return { state: state, kind: "success", solid: true, badge: qsTr("Official"), icon: "check_circle", iconError: false, bad: false, opensSheet: true,
                     line: qsTr("Signed by %1 and the RuyaOS store").arg(name !== "" ? name : key) }
        case "developer":
            return { state: state, kind: "warning", solid: true, badge: qsTr("Developer"), icon: "info", iconError: false, bad: false, opensSheet: true,
                     line: name !== "" ? qsTr("Signed by %1 · key %2").arg(name).arg(key) : qsTr("Signed by key %1").arg(key) }
        case "changed":
            return { state: state, kind: "error", solid: true, badge: qsTr("Changed since signed"), icon: "error", iconError: true, bad: true, opensSheet: false,
                     line: qsTr("This package was changed after it was signed.") }
        case "revoked": {
            const reason = info.revokedReason ?? ""
            return { state: state, kind: "error", solid: true, badge: qsTr("Removed for safety"), icon: "error", iconError: true, bad: true, opensSheet: false,
                     line: reason !== "" ? qsTr("Removed for safety: %1").arg(reason) : qsTr("Removed for safety") }
        }
        }
        return { state: "unverified", kind: "error", solid: true, badge: qsTr("Unverified"), icon: "warning", iconError: true, bad: false, opensSheet: true,
                 line: qsTr("Not signed. Anyone could have changed it.") }
    }

    // The "Seen before" value for the key's `keyState` ("new" | "same" | "different"; "" = unsigned).
    function keyStateText(state) {
        if (language === undefined)
            return ""
        return state === "same" ? qsTr("Yes, the same key as the installed game")
             : state === "different" ? qsTr("No, a different key")
             : qsTr("No, a new key")
    }

    // The note under the signer sheet's rows, by tier.
    function noteText(tier) {
        if (language === undefined)
            return ""
        return tier === "official" ? qsTr("The developer and the RuyaOS store both signed every file.")
             : tier === "developer" ? qsTr("A signature shows that this key signed every file. It doesn't prove who the developer is.")
             : qsTr("Nobody signed this package, so nothing shows who made it or whether it was changed.")
    }

    // The shell's own words for a permission key of the Inspect record (04 §5.4); `words` (the service's
    // English) only for a key the shell has no words for. "always" is the row every game gets.
    function permissionWords(key, words) {
        if (language === undefined)
            return ""
        switch (key) {
        case "always": return qsTr("Plays sound, uses graphics")
        case "input:controllers": return qsTr("Uses controllers")
        case "input:controllers+keyboard-mouse": return qsTr("Uses controllers, keyboard and mouse")
        case "input:all-devices": return qsTr("Accesses all devices")
        case "network": return qsTr("Uses the network")
        case "removable_media:read":
        case "removable_media": return qsTr("Reads files on USB drives")
        case "removable_media:write": return qsTr("Changes files on USB drives")
        case "multiarch": return qsTr("Runs 32-bit programs")
        case "gamemode":
        case "realtime": return qsTr("Asks the system to prioritise it")
        case "devel": return qsTr("Can inspect other programs")
        case "network+removable_media": return qsTr("Uses the network and reaches USB drives")
        }
        return words ?? key
    }

    // Seconds as m:ss ("Trailer · 1:05"); minutes past 59 stay minutes.
    function clock(seconds) {
        const total = Math.max(0, Math.floor(seconds || 0))
        const s = total % 60
        return Math.floor(total / 60) + ":" + (s < 10 ? "0" : "") + s
    }
}
