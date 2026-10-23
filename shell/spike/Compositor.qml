import QtQuick
import QtWayland.Compositor
import QtWayland.Compositor.XdgShell
import RuyaShell

// T-123 spike (ADR-002 option A): ruya-shell as the Wayland compositor. The real Shell is the
// bottom layer; client toplevels are shown fullscreen above it; the Shell's Guide overlay
// (systemPanel) is moved into a layer above the clients.
//
// Not part of the RuyaShell module and its tests (the Windows Qt kit has no QtWaylandCompositor);
// installed to /usr/share/ruya-shell/spike and loaded with `ruya-shell --load <this file>` by
// ruya-compositor-spike@.service. Clients connect to $XDG_RUNTIME_DIR/ruya-0.
//
// Input: a client surface item with active focus forwards keys to its client. Its Keys handler
// runs first and takes the Guide keys (Shell.isGuideKey), so Guide opens the overlay instead of
// reaching the app; closing the overlay gives the focus (and so the keys) back to the client.
WaylandCompositor {
    id: compositor
    socketName: "ruya-0"

    property Item appItem: null       // the client surface on top, if any
    property Item panel: null         // Shell's systemPanel, re-parented above the clients

    function findByName(item, name) {
        if (item.objectName === name)
            return item
        for (let i = 0; i < item.children.length; ++i) {
            const hit = findByName(item.children[i], name)
            if (hit)
                return hit
        }
        return null
    }

    function focusApp() {
        if (appItem && panel && !panel.open)
            appItem.forceActiveFocus()
    }

    WaylandOutput {
        id: output
        sizeFollowsWindow: true
        window: Window {
            id: win
            width: 1920
            height: 1080
            visibility: Window.FullScreen
            color: Theme.background
            title: "RuyaOS"

            Shell {
                id: shell
                anchors.fill: parent
                version: "spike"
                focus: true
            }
            Item {
                id: appLayer
                anchors.fill: parent
            }
            Item {
                id: overlayLayer
                anchors.fill: parent
            }
        }
    }

    Component.onCompleted: {
        panel = findByName(shell, "systemPanel")
        panel.parent = overlayLayer
        console.info("ruya-spike: compositor up, socket", socketName)
    }

    // The app went away: drop its item and give the shell the screen and the keys back. Connected
    // from here, not as a handler inside the delegate: there it ran with a dead context in the VM
    // ("compositor" was null) and the last frame stayed on screen.
    function appClosed(item) {
        console.info("ruya-spike: client gone")
        if (appItem === item)
            appItem = null
        item.destroy()
        if (!panel.open)
            shell.forceActiveFocus()
    }

    Connections {
        target: compositor.panel
        function onOpenChanged() {
            console.info("ruya-spike: overlay", compositor.panel.open ? "open" : "closed")
            // Shell refocuses its own tiles when the overlay closes; the client comes after that.
            if (!compositor.panel.open)
                Qt.callLater(compositor.focusApp)
        }
    }

    Component {
        id: surfaceComponent
        ShellSurfaceItem {
            anchors.fill: parent
            Keys.onPressed: event => {
                if (shell.isGuideKey(event.key)) {
                    console.info("ruya-spike: Guide taken from the client")
                    if (!event.isAutoRepeat)
                        compositor.panel.open = true
                    event.accepted = true
                }
            }
            Keys.onReleased: event => {
                if (shell.isGuideKey(event.key))
                    event.accepted = true
            }
            onActiveFocusChanged: console.info("ruya-spike: client focus", activeFocus)
        }
    }

    XdgShell {
        onToplevelCreated: (toplevel, xdgSurface) => {
            const item = surfaceComponent.createObject(appLayer, { shellSurface: xdgSurface })
            toplevel.sendFullscreen(Qt.size(win.width, win.height))
            item.surfaceDestroyed.connect(() => compositor.appClosed(item))
            compositor.appItem = item
            item.forceActiveFocus()
            console.info("ruya-spike: toplevel", toplevel.appId, toplevel.title)
        }
    }
}
