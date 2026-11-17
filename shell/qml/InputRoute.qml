import QtQuick
import RuyaShell

// Tells Ruya Input who is in front (RUY-409, 06 §5.1-5.2, Input1.SetRoute), as UsagePresence tells
// the play ledger: the shell is the only source of the route. Shell.qml feeds it what it already
// knows; this object works out the route and sends it on every change:
//   locked   nobody is signed in (the picker, its PIN pad after Lock or a switch, no profile yet):
//            never with a profile, so no game can keep a pad
//   shell    Home, a page, the Hub over Home, or a window whose running instance the shell does not
//            know (Input1 needs the instance and the app id for "app"), with no game held (below)
//   overlay  the Hub, a system dialog or the screen saver over the app in front, or that app frozen:
//            always with its instance and app id, so its pads stay, held in neutral (RUY-541: a
//            Freeze by the Hub keeps them; a one-pad game keeps the player's pad). Also with no app
//            in front while Shell.qml names a held game (RUY-611): one frozen behind Home or the Hub,
//            or one being closed until it has exited, so a game that saves its controller choice on
//            quit (LibreQuake: "Gamepad removed" -> joy_device -1) still finds its pads
//   app      the app in front has the keys and is not frozen
// Two gaps between windows keep the pads (RUY-814; Input destroys them on "shell"):
//   - a new window whose instance Session1 has not yet named (`lookupPending`) holds the last sent
//     "app"/"overlay" of this profile while that instance still runs, until the reply comes (no timer):
//     the reply naming the same instance changes nothing, another instance or none sends where it ends up;
//   - the last window of a running instance closing, and the next one not mapped yet (an installer, then
//     the game): Shell.qml names the instance as the held game ("overlay") for `windowGapMs`.
// A window of the same client (same pid) takes its sibling's instance at once and has no lookup.
// The Thaw (overlay -> app with the same instance) gives the app the same pads back. Lock, a profile
// change and Home with no game held ("locked" or "shell", no instance) still make Input destroy them. The calls are
// coalesced to one per event-loop turn (Qt.callLater), so a change that moves several inputs at once
// (Lock clears the profile and the app in front) sends only where it ends up. A failed call is
// logged by Input and sent again with the next change; Input also sends the route again when the
// service restarts.
QtObject {
    id: router

    property bool signedIn: false
    // Profiles.activeProfile.
    property string profile: ""
    // An app item has the screen (not behind Home, shown to the signed-in profile).
    property bool appInFront: false
    // Session1's instance and Flatpak id of the app in front ("" when the shell does not know them).
    property string instance: ""
    property string appId: ""
    // The app in front is frozen (the Hub paused it; a Thaw may be on its way).
    property bool frozen: false
    // Something of the shell covers the app and takes the keys (the Hub, a system dialog, the saver).
    property bool overlay: false
    // A game whose pads outlive the screen (RUY-611), used only with no app in front: Session1's
    // instance and Flatpak id of a frozen game behind Home, or of a game being closed (Shell.qml).
    property string heldInstance: ""
    property string heldAppId: ""

    // The instance lookup of the app in front is pending (RUY-814): a window just mapped and Session1
    // has not yet said which instance its process belongs to (Shell.qml: the focused record's `pending`).
    property bool lookupPending: false
    // The instances Session1 lists as running, for the window hold below.
    property var runningInstances: []

    // What was last sent (the hold below keeps it).
    property string sentRoute: ""
    property string sentInstance: ""
    property string sentAppId: ""
    property string sentProfile: ""

    readonly property bool holding: signedIn && !appInFront && heldInstance !== "" && heldAppId !== ""

    // The window hold (RUY-814): while the front window's instance is not yet known, the last sent
    // "app"/"overlay" of this profile stays, as long as that instance still runs. A second window of a
    // running game (xwayland-satellite gives each X window its own surface) would else send "shell" for
    // one reply's time, and Input destroys the pads on "shell". It needs no timer: the reply ends it
    // (a reply naming another instance or none sends where things end up).
    readonly property bool windowHold: signedIn && appInFront && lookupPending && instance === ""
                                       && (sentRoute === "app" || sentRoute === "overlay")
                                       && sentInstance !== "" && sentAppId !== "" && sentProfile === profile
                                       && runningInstances.includes(sentInstance)

    readonly property string route: !signedIn ? "locked"
                                  : holding ? "overlay"
                                  : windowHold ? (overlay ? "overlay" : sentRoute)
                                  : !appInFront || instance === "" || appId === "" ? "shell"
                                  : overlay || frozen ? "overlay" : "app"
    readonly property string routeInstance: holding ? heldInstance
                                          : windowHold ? sentInstance
                                          : route === "app" || route === "overlay" ? instance : ""
    readonly property string routeAppId: holding ? heldAppId
                                       : windowHold ? sentAppId : routeInstance !== "" ? appId : ""
    readonly property string routeProfile: route === "locked" ? "" : profile

    readonly property string request: route + "|" + routeInstance + "|" + routeAppId + "|" + routeProfile

    function send() {
        sentRoute = route
        sentInstance = routeInstance
        sentAppId = routeAppId
        sentProfile = routeProfile
        Input.setRoute(route, routeInstance, routeAppId, routeProfile)
    }

    onRequestChanged: Qt.callLater(router.send)
    Component.onCompleted: send()
}
