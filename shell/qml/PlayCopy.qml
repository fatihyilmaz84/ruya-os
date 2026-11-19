pragma Singleton
import QtQuick
import RuyaShell

// The words of installing a .play package from a drive (04 §5.4, RUY-98): the sources page, the package page,
// the confirm sheet, the progress line and the result dialog read their sentences here, so a status means the
// same thing wherever it shows. The trust words (badge, signer, permissions) are PlayTrust's.
//
// Every function reads `language`, so a binding that calls one is evaluated again when the UI language changes.
QtObject {
    id: root

    readonly property string language: DeviceSettings.language

    // Whether this profile may see "Install from USB" at all. True today: a Standard profile sees it and an admin's
    // PIN gates the install (05 §18 item 4). Restricted profiles (parental controls, T-211) get false here once
    // that flag exists; the Store's entry, Settings -> Storage and the sources page all read this one property.
    // It is also false while ruya-play is not running (`Play.available`): the list would be empty even with a stick
    // plugged in (RUY-809).
    readonly property bool installFromUsbAllowed: Play.available

    // "Folder" / "ZIP file": what a source is, under its name.
    function kindText(kind) {
        if (language === undefined)
            return ""
        return kind === "zip" ? qsTr("ZIP file") : qsTr("Folder")
    }

    function controllerText(level) {
        if (language === undefined)
            return ""
        return level === "full" ? qsTr("Full controller support")
             : level === "partial" ? qsTr("Partial controller support")
             : qsTr("Needs keyboard and mouse")
    }

    // The age badge's words (the Store page's).
    function ageText(label) {
        if (language === undefined)
            return ""
        return label === "all" ? qsTr("All ages") : !label ? qsTr("Not rated") : qsTr("Ages %1").arg(label)
    }

    // "Version 1.142.0 · 4.7 GB · 1-2 players · Full controller support"
    function metaLine(info, sizeText) {
        if (language === undefined || !info)
            return ""
        return qsTr("Version %1 · %2 · %3 players · %4").arg(info.version ?? "").arg(sizeText)
            .arg(info.players ?? "").arg(controllerText(info.controller))
    }

    // The three things a player is told while a job runs; the fourth phase word covers the last two phases.
    function phaseWords(phase) {
        if (language === undefined)
            return ""
        switch (phase) {
        case "staging": return qsTr("Copying from the USB drive")
        case "verifying": return qsTr("Checking the signature")
        case "vetting-art": return qsTr("Checking the pictures")
        }
        return qsTr("Installing")
    }

    // Cancel is offered until the point of no return (from `committing` on the service says "too-late").
    function cancelAllowed(phase) {
        return phase !== "committing" && phase !== "installing"
    }

    function progressLine(phase, percent) {
        if (language === undefined)
            return ""
        return qsTr("%1 · %2 %").arg(phaseWords(phase)).arg(percent)
    }

    // The sentence of a JobFinished status other than ok and cancelled (the result dialog). `toFree` = the bytes
    // the player has to free (disk-full), already formatted.
    function jobStatusText(status, toFree) {
        if (language === undefined)
            return ""
        switch (status) {
        case "invalid-package": return qsTr("This package is damaged or incomplete. Copy it to the USB drive again.")
        case "bad-signature": return qsTr("This package was changed after it was signed. Get a fresh copy from the developer.")
        case "different-developer": return qsTr("This isn't the same developer as the installed game. An admin can forget this game's data and key in Options.")
        case "needs-developer-mode": return qsTr("Unsigned packages need developer mode. An admin can turn it on in Settings.")
        case "revoked": return qsTr("This game was removed for safety and can't be installed.")
        case "unsupported": return qsTr("This game needs a newer RuyaOS. Update the system, then try again.")
        case "disk-full": return qsTr("There isn't enough space. Free %1, then try again.").arg(toFree ?? "")
        }
        return qsTr("The install didn't finish. Try again.")
    }

    // The error toast of a method status other than ok (the call was refused).
    function methodStatusText(status) {
        if (language === undefined)
            return ""
        switch (status) {
        case "forbidden": return qsTr("Only an admin can install from USB.")
        case "busy": return qsTr("Another install is running. Try again when it ends.")
        case "unknown-source": return qsTr("The USB drive was removed. Plug it in, then try again.")
        case "too-late": return qsTr("It's too late to cancel. The install is finishing.")
        }
        return qsTr("Something went wrong. Try again.")
    }

    // Why Install is dimmed on the package page: "" when the package can be installed. It follows the service's
    // verdict (what Install would end with); a package that needs a newer system is "unsupported" too.
    function blockReason(info) {
        if (language === undefined || !info)
            return ""
        const verdict = info.verdict ?? "ok"
        if (verdict === "ok")
            return info.requirement === "unsupported" ? jobStatusText("unsupported") : ""
        if (verdict === "bad-signature")
            return qsTr("It can't be installed. Get a fresh copy from the developer.")
        // A package refused for a permission above its tier's ceiling is not damaged: the first problem names
        // the permission (`/permissions/<key>`), and the advice is a signed version (05 §8, RUY-884).
        const first = info.problems && info.problems.length > 0 ? info.problems[0] : null
        if (verdict === "invalid-package" && first && first.code === "ceiling.refused")
            return qsTr("This game is not signed, so it may not have this permission: %1. Ask the developer for a signed version.")
                .arg(PlayTrust.permissionWords(first.path.substring(first.path.lastIndexOf("/") + 1)))   // an unknown key shows itself
        return jobStatusText(verdict)
    }

    // The toasts of an install that ends while its package page is closed (the page's own result is its toast or dialog).
    function installedToast() {
        return language === undefined ? "" : qsTr("Installed", "Toast: the install finished")
    }

    function notInstalledToast() {
        return language === undefined ? "" : qsTr("Not installed", "Toast: the install failed")
    }

    // An installed game that was revoked after it was installed: Play is replaced by Remove and this line.
    function revokedInstalledLine() {
        return language === undefined ? "" : qsTr("It won't start. You can still remove it.")
    }

    function removeLabel() {
        return language === undefined ? "" : qsTr("Remove")
    }
}
