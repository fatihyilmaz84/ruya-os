import QtQuick
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

    // The picture's load state. While it loads (not when it failed or is absent) a gleam crosses
    // the placeholder (04 §3.8): not under reduced motion or on the Performance tier.
    property int imageStatus: image.status
    readonly property bool pending: picture.length > 0 && imageStatus === Image.Loading
    readonly property bool shimmering: shimmer && pending && Theme.shimmerOn

    readonly property real hue: {
        let h = 0
        for (let i = 0; i < appId.length; ++i)
            h = (h * 31 + appId.charCodeAt(i)) % 360
        return h / 360
    }

    radius: Theme.radiusM * u
    clip: true
    gradient: Gradient {
        GradientStop { position: 0.0; color: Theme.artTop(art.hue) }
        GradientStop { position: 1.0; color: Theme.artBottom(art.hue) }
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
        source: art.picture.length > 0 ? (art.picture.startsWith("/") ? "file://" + art.picture : art.picture) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
}
