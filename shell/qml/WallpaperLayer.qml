pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import RuyaShell

// The wallpaper in L0 (04 §3.5, T-208): the chosen picture, a dim layer over it and, on pages, the
// blurred copy.
//
// - Two `Image`s decode asynchronously at the screen size. A new picture loads into the idle one
//   and fades in over the old one (`tintMs`); once it covers, the old one is released, so at most
//   two pictures are in memory while changing and one otherwise (`decoded`).
// - `blurred` (a page is on top, T-208): one `MultiEffect` blurs a quarter-size copy of the pictures
//   (`ShaderEffectSource`), the shared blurred L0 of 04 §3.6, never a second full-screen blur. Without
//   blur (Performance tier) the picture stays sharp and is darkened to at least
//   `Theme.wallpaperDimUnblurred`.
// - The dim is the owner's `DeviceSettings.wallpaperDim`, raised for a bright picture until white text keeps
//   4.5:1 over its bright part (`Wallpapers.requiredDim`, 04 §7).
// - A picture that cannot be loaded (or an id that no longer exists) emits `failed`; the shell
//   toasts and goes back to the default look.
Item {
    id: layer

    property string wallpaper: DeviceSettings.wallpaper
    property bool blurred: false                        // a page (not Home) is on top
    property real dim: DeviceSettings.wallpaperDim

    readonly property var entry: find(wallpaper)
    readonly property string target: entry.source ?? ""    // the picture that should be shown ("" = none)
    // The picture that is (being) shown, and whether it covers the backdrop completely (stays true
    // across a change of picture; false again only when the default look comes back).
    property Image front: null
    property bool covering: false
    readonly property bool has: front !== null
    // How many pictures are decoded or loading right now.
    readonly property int decoded: (picA.source.toString().length > 0 ? 1 : 0) + (picB.source.toString().length > 0 ? 1 : 0)

    readonly property bool blurActive: blurred && Theme.blurMax > 0
    readonly property real requiredDim: Wallpapers.requiredDim(entry.peak ?? 0)
    readonly property real effectiveDim: Math.max(dim, requiredDim, blurred && Theme.blurMax <= 0 ? Theme.wallpaperDimUnblurred : 0)

    signal failed(string id, string reason)

    property int zTop: 0
    property Image pending: null

    function find(id) {
        if (id === "")
            return ({})
        for (const b of Wallpapers.bundled) {
            if (b.id === id)
                return b
        }
        for (const u of Wallpapers.user) {
            if (u.id === id)
                return u
        }
        return ({})
    }

    function reportMissing(id) {
        if (id === wallpaper && !find(id).source)     // still unusable
            failed(id, "missing")
    }

    function retarget() {
        if (width <= 0 || height <= 0) {
            Qt.callLater(retarget)            // sourceSize needs the size, or a 4K file would decode whole
            return
        }
        // Not `target`: this runs from onEntryChanged, before the binding that follows it has been re-evaluated.
        const target = entry.source ?? ""
        if (target === "") {
            for (const p of [picA, picB]) {
                p.instant = false
                p.on = false
            }
            pending = null
            front = null
            covering = false
            if (wallpaper !== "")
                Qt.callLater(reportMissing, wallpaper)    // not while the setting is being re-evaluated
            return
        }
        if (front && front.source.toString() === target) {
            pending = null
            return
        }
        if (pending && pending.source.toString() === target)
            return
        const spare = front === picA ? picB : picA
        spare.on = false
        spare.instant = true
        spare.source = target
        pending = spare
    }

    function picStatus(pic) {
        if (pic !== pending)
            return
        if (pic.status === Image.Ready) {
            pending = null
            pic.z = ++zTop
            pic.instant = false
            pic.on = true
            front = pic
        } else if (pic.status === Image.Error) {
            console.warn("ruya-shell: cannot load the wallpaper", wallpaper)
            pic.source = ""
            pending = null
            failed(wallpaper, "load")
        }
    }

    // A picture reached full opacity: it covers, and the one below is not needed any more.
    function picCovers(pic) {
        covering = true
        const other = pic === picA ? picB : picA
        other.instant = true
        other.on = false
    }

    onEntryChanged: retarget()
    Component.onCompleted: retarget()

    component Pic: Image {
        id: pic
        property bool on: false
        property bool instant: false     // leaves without a fade (it is already covered)
        anchors.fill: parent
        asynchronous: true
        cache: false                     // nothing keeps a decoded picture once the source is cleared
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(layer.width, layer.height)
        opacity: on && status === Image.Ready ? 1 : 0
        Behavior on opacity {
            enabled: !pic.instant
            NumberAnimation { duration: Theme.tintMs; easing.type: Easing.InOutQuad }
        }
        onOpacityChanged: {
            if (opacity === 1 && on)
                layer.picCovers(pic)
            else if (opacity === 0 && !on && source.toString().length > 0)
                source = ""              // released once it has faded out
        }
        onStatusChanged: layer.picStatus(pic)
    }

    Item {
        id: pictures
        objectName: "wallpaperPictures"
        anchors.fill: parent
        Pic { id: picA; objectName: "wallpaperA" }
        Pic { id: picB; objectName: "wallpaperB" }
    }

    // The shared blurred copy: a quarter-size texture of the pictures, blurred once, faded in over
    // the sharp pictures while a page is open.
    Loader {
        id: blurLoader
        objectName: "wallpaperBlurLoader"
        anchors.fill: parent
        active: layer.has && Theme.blurMax > 0
        sourceComponent: Item {
            ShaderEffectSource {
                id: reduced
                visible: false
                sourceItem: pictures
                textureSize: Qt.size(Math.max(1, layer.width / 4), Math.max(1, layer.height / 4))
            }
            MultiEffect {
                objectName: "wallpaperBlur"
                anchors.fill: parent
                source: reduced
                visible: opacity > 0
                opacity: layer.blurred ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
                autoPaddingEnabled: false
                blurEnabled: true
                blur: 1.0
                blurMax: Theme.blurMax
            }
        }
    }

    Rectangle {
        objectName: "wallpaperDim"
        anchors.fill: parent
        color: Theme.background
        opacity: layer.has ? layer.effectiveDim : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
    }
}
