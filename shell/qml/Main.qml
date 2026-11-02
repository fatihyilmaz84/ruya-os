import QtQuick
import RuyaShell

Window {
    id: window

    required property string version
    property bool windowed: false        // --windowed, development only
    readonly property alias shell: shell // for the compositor (compositor/Compositor.qml, Linux)

    width: 1920
    height: 1080
    visibility: windowed ? Window.Windowed : Window.FullScreen   // implies visible; don't also set `visible`
    color: Theme.background
    title: "RuyaOS"

    Shell {
        id: shell
        anchors.fill: parent
        version: window.version
        focus: true
        // --reverse (RTL readiness check): mirror anchors and horizontal lists for a right-to-left layout.
        LayoutMirroring.enabled: Application.layoutDirection === Qt.RightToLeft
        LayoutMirroring.childrenInherit: true
    }
}
