import QtQuick
import RuyaShell

Window {
    id: window

    required property string version
    property bool windowed: false        // --windowed, development only

    width: 1920
    height: 1080
    visibility: windowed ? Window.Windowed : Window.FullScreen   // implies visible; don't also set `visible`
    color: Theme.background
    title: "RuyaOS"

    Shell {
        anchors.fill: parent
        version: window.version
        focus: true
    }
}
