pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import RuyaShell

// Art of an app: a gradient whose hue comes from the app id (the ProfileCard idea), the first
// letter of the name, and the service's picture on top when it has one. Used by the Store cards
// and the detail page.
Rectangle {
    id: art

    property real u: 1
    property string appId
    property string appName
    property string picture      // path from the app record (tile or hero), may be empty
    property bool monogram: true // the letter; off for full-screen art (the Home hero)
    property bool shimmer: true  // the gleam while loading; off for the Home hero (it fades in over the backdrop)
    property bool bare: false    // no fallback fill: the Home hero over a wallpaper shows the wallpaper until the picture is there (T-208)

    // The picture's load state. While it loads (not when it failed or is absent) a gleam crosses
    // the placeholder (04 §3.8): not under reduced motion or on the Performance tier.
    property int imageStatus: image.status
    readonly property bool pending: picture.length > 0 && imageStatus === Image.Loading
    readonly property bool shimmering: shimmer && pending && Theme.shimmerOn

    // The art's colours for the card glow (T-281, 04 §3.8): the sampled colour of the picture
    // (ArtPalette decodes it once, in the background, and remembers it) and how loud the glow may be.
    // Until it is known, and for a card without a picture, the glow takes the placeholder's own hue.
    // Only cards that glow ask for it (`glowing`); the hero and the saver do not.
    property bool glowing: false
    property var sample: ({})
    readonly property bool sampled: sample.color !== undefined
    readonly property color glowColor: sampled ? sample.color : Theme.glowFallback(hue)
    readonly property real glowStrength: sampled ? sample.strength : Theme.glowFallbackStrength

    function lookup() {
        sample = glowing && picture.length > 0 ? ArtPalette.colorsOf(picture) : ({})
    }
    onPictureChanged: lookup()
    onGlowingChanged: lookup()
    Component.onCompleted: lookup()
    Connections {
        target: ArtPalette
        function onSampled(source) {
            if (source === art.picture)
                art.lookup()
        }
    }

    readonly property real hue: {
        let h = 0
        for (let i = 0; i < appId.length; ++i)
            h = (h * 31 + appId.charCodeAt(i)) % 360
        return h / 360
    }

    radius: Theme.radiusM * u
    border.width: 0    // the focus ring is the card's own item above the picture (ArtCard, the Store card)
    clip: true      // rectangular: on the software renderer the picture's square corners stay (no MultiEffect there)

    // The picture's corners follow `radius` (a Rectangle's `clip` is rectangular): on a GPU the
    // picture is drawn through a rounded mask, as the wallpaper picker's tiles are. A square art
    // (`radius` 0, the Home hero) needs no mask.
    readonly property alias maskItem: imageMask
    readonly property bool masked: GraphicsInfo.api !== GraphicsInfo.Software && radius > 0
    // `bare`: both stops clear. (Setting `gradient` to null instead leaves a white rectangle on a GPU window.)
    gradient: Gradient {
        GradientStop { position: 0.0; color: art.bare ? "transparent" : Theme.artTop(art.hue) }
        GradientStop { position: 1.0; color: art.bare ? "transparent" : Theme.artBottom(art.hue) }
    }

    Text {
        objectName: "artMonogram"
        visible: art.monogram
        anchors.centerIn: parent
        text: art.appName.charAt(0).toUpperCase()
        color: Theme.text
        opacity: 0.85
        font.pixelSize: Theme.typeHero * art.u
        font.weight: Theme.weightLight
    }

    // One gradient quad moving at Theme.shimmerSpeed design px per second, looping.
    Item {
        anchors.fill: parent
        clip: true
        visible: art.shimmering
        Rectangle {
            id: gleam
            objectName: "artShimmer"
            width: art.width * 0.35
            height: art.height
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Theme.glassSheenEnd }
                GradientStop { position: 0.5; color: Theme.shimmerPeak }
                GradientStop { position: 1.0; color: Theme.glassSheenEnd }
            }
        }
        NumberAnimation {
            objectName: "artShimmerAnimation"
            target: gleam
            property: "x"
            from: -gleam.width
            to: art.width
            duration: Math.max(1, Math.round((art.width + gleam.width) / (Theme.shimmerSpeed * art.u) * 1000 * Theme.motionScale))
            loops: Animation.Infinite
            running: art.shimmering
        }
    }

    Image {
        id: image
        objectName: "artImage"
        anchors.fill: parent
        visible: status === Image.Ready
        // A path (Linux "/..." or a Windows drive "C:/...") becomes a file URL; a URL stays as it is.
        source: art.picture.length > 0 ? (art.picture.startsWith("/") ? "file://" + art.picture
                                          : /^[A-Za-z]:\//.test(art.picture) ? "file:///" + art.picture : art.picture) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        layer.enabled: art.masked && visible
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: art.maskItem
            autoPaddingEnabled: false
        }
    }

    Rectangle {
        id: imageMask
        objectName: "artImageMask"
        anchors.fill: parent
        radius: art.radius
        visible: false
        layer.enabled: art.masked
    }
}
