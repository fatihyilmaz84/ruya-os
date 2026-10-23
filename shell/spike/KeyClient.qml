import QtQuick

// T-123 spike: a stand-in app for the compositor spike. It shows and logs every key it receives,
// so the Outcome can show which keys reached the app. Run it as a Wayland client of the spike:
//   QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=ruya-0 ruya-shell --load KeyClient.qml
Window {
    id: win
    width: 1280
    height: 720
    visibility: Window.FullScreen
    color: "#1f4e5f"
    title: "Spike client"

    property int count: 0
    property string last: "-"

    Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            win.count += 1
            win.last = event.text !== "" ? event.text : "0x" + event.key.toString(16)
            console.info("spike-client: key", win.last, "count", win.count)
        }
    }

    Rectangle {
        id: spinner
        width: 160
        height: 160
        x: 120
        y: 120
        color: "#f2a541"
        RotationAnimation on rotation { from: 0; to: 360; duration: 4000; loops: Animation.Infinite }
    }

    Text {
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        color: "white"
        font.pixelSize: 72
        text: "Spike client\nkeys received: " + win.count + "\nlast: " + win.last
    }
}
