import QtQuick
import RuyaShell

// The Shell's modal layer (T-272): full screen, above pages and toasts. It offers the L0 layer
// (`glassSource`) that the glass sheets of the picker modals blur (GlassSheet finds it by walking
// up its parents).
Item {
    property Item glassSource: null
}
