import QtQuick
import QtWayland.Compositor
import QtWayland.Compositor.XdgShell
import RuyaShell

// ruya-shell as the Wayland compositor (ADR-002 option A, T-130). The output's window is the
// ordinary Main window, so the shell is the same as on the Windows host; every xdg toplevel
// becomes a fullscreen ShellSurfaceItem handed to Shell.addApp, which puts it in the app layer
// (above home and pages, below toasts, modals and the Guide overlay) and gives it the focus.
// KeyRouter (src/input) takes the Guide keys before the focused surface item forwards a key to
// its client; every other key reaches the client.
//
// Linux only: the module RuyaCompositor is built when RUYA_COMPOSITOR is on (the image build);
// the Windows Qt kit has no QtWaylandCompositor. The shell's own clients (VM test clients)
// connect to $XDG_RUNTIME_DIR/ruya-0; a profile's apps to /run/ruya-wayland/ruya-<id>, a socket
// only that profile's Unix user can open (ProfileSockets, ADR-023, T-164). Each client is mapped
// to a profile by its peer uid (AppGate.verdict): the signed-in profile's clients and the shell's
// own are accepted, every other client is closed before it can show anything.
WaylandCompositor {
    id: compositor
    socketName: "ruya-0"

    // Set by main.cpp, as for Main.
    required property string version
    property bool windowed: false

    // One socket per profile, made when the profile list is known and kept in step with it.
    ProfileSockets {
        id: profileSockets
        compositor: compositor
        directory: AppGate.socketDir
    }
    function syncSockets() {
        const users = Profiles.profiles.map(p => AppGate.unixUser(p.id)).filter(u => u !== "")
        profileSockets.sync(users)
    }
    Connections {
        target: Profiles
        function onProfilesChanged() { compositor.syncSockets() }
    }

    // Whose client this is, decided again for every surface and window.
    function verdictOf(client) {
        const active = Profiles.activeProfile
        const activeUid = active !== "" ? AppGate.uidOf(AppGate.unixUser(active)) : -1
        return AppGate.verdict(client ? client.userId : -1, AppGate.shellUid, active, activeUid)
    }
    // Closed on the next turn of the event loop: never inside the client's own request.
    function refuse(client, verdict, what) {
        console.info("ruya-compositor: refused", what, "of uid", client ? client.userId : -1,
                     "pid", client ? client.processId : -1, "(" + verdict.reason + ")")
        Qt.callLater(() => { if (client) client.close() })
    }
    onSurfaceCreated: surface => {
        const verdict = verdictOf(surface.client)
        if (!verdict.accepted)
            refuse(surface.client, verdict, "surface")
    }

    WaylandOutput {
        id: output
        sizeFollowsWindow: true
        window: Main {
            id: win
            version: compositor.version
            windowed: compositor.windowed
        }
    }

    Component.onCompleted: {
        console.info("ruya-compositor: up, socket", socketName)
        syncSockets()
    }

    // The client went away: dropping the item makes the shell take the screen and the focus back
    // (Shell's guard on each app item). Connected from here, not as a handler inside the delegate:
    // there it ran with a dead context in the T-123 spike and the last frame stayed on screen.
    function appClosed(item) {
        console.info("ruya-compositor: app gone", item.objectName)
        item.destroy()
    }

    Component {
        id: surfaceComponent
        ShellSurfaceItem {
            property XdgToplevel toplevel: null
            objectName: "app:" + (toplevel ? toplevel.appId : "")
            onActiveFocusChanged: console.info("ruya-compositor: app focus", objectName, activeFocus)
        }
    }

    // Where the keys go while an app is open (the overlay's list, or the app), for the VM log.
    Connections {
        target: win
        function onActiveFocusItemChanged() {
            if (win.shell.appOpen && win.activeFocusItem)
                console.info("ruya-compositor: focus", win.activeFocusItem.objectName)
        }
    }

    // Apps that ask for the screen to stay on (video players, games): each inhibitor is a reason
    // the idle clock does not count down (T-202; the shell's debug row lists them, the log has +/-).
    IdleInhibitManager {
        onInhibitorAdded: id => IdleInhibit.acquire("wayland:" + id)
        onInhibitorRemoved: id => IdleInhibit.release("wayland:" + id)
    }

    XdgShell {
        onToplevelCreated: (toplevel, xdgSurface) => {
            const client = xdgSurface.surface.client
            const verdict = compositor.verdictOf(client)
            if (!verdict.accepted) {
                compositor.refuse(client, verdict, "window")
                return
            }
            // Parented to the shell so it is never garbage-collected; addApp moves it into the app layer.
            const item = surfaceComponent.createObject(win.shell, { shellSurface: xdgSurface, toplevel: toplevel })
            item.surfaceDestroyed.connect(() => compositor.appClosed(item))
            toplevel.sendFullscreen(Qt.size(win.width, win.height))
            // The app is shown only to its profile ("" = the shell's own: to whoever is signed in).
            win.shell.addApp(item, verdict.profile)
            console.info("ruya-compositor: app", toplevel.appId, toplevel.title, "uid", client.userId,
                         "profile", verdict.profile !== "" ? verdict.profile : "(shell)")
        }
    }
}
