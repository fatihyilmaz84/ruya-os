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

    readonly property real hue: {
        let h = 0
        for (let i = 0; i < appId.length; ++i)
            h = (h * 31 + appId.charCodeAt(i)) % 360
        return h / 360
    }

    radius: Theme.radiusM * u
    clip: true
    gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.hsla(art.hue, 0.55, 0.42, 1) }
        GradientStop { position: 1.0; color: Qt.hsla(art.hue, 0.6, 0.18, 1) }
    }

    Text {
        anchors.centerIn: parent
        text: art.appName.charAt(0).toUpperCase()
        color: Theme.text
        opacity: 0.85
        font.pixelSize: Theme.typeHero * art.u
        font.weight: Font.Light
    }

    Image {
        anchors.fill: parent
        visible: status === Image.Ready
        source: art.picture.length > 0 ? (art.picture.startsWith("/") ? "file://" + art.picture : art.picture) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
}
