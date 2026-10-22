pragma Singleton
import QtQuick

// One user-facing message per Profiles1 status (api/dbus/org.ruyaos.Profiles1.xml), shared by
// Settings -> Profiles and the first-boot setup.
QtObject {
    function describe(status, attemptsLeft, retryAfterSecs) {
        switch (status) {
        case "wrong-pin":
            return attemptsLeft > 0 ? qsTr("Wrong PIN. %n attempt(s) left.", "", attemptsLeft) : qsTr("Wrong PIN.")
        case "locked-out":
            return retryAfterSecs > 0 ? qsTr("Too many attempts. Try again in %1 s.").arg(retryAfterSecs)
                                      : qsTr("Too many attempts. Try again later.")
        case "pin-required":
            return qsTr("A PIN is required.")
        case "unknown-profile":
            return qsTr("That profile no longer exists.")
        case "invalid":
            return qsTr("That isn't allowed. Check the name and the PIN (4 to 6 digits).")
        case "not-allowed":
            return qsTr("Only an admin can do that.")
        default:
            return qsTr("Something went wrong. Please try again.")
        }
    }
}
