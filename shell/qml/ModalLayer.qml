import QtQuick

// The Shell's modal layer (T-272): full screen, above pages and toasts. It offers the L0 layer
// (`glassSource`) that the glass sheets of the picker modals blur (GlassSheet finds it by walking
// up its parents).
Item {
    property Item glassSource: null
    // The Hub or "Who's playing?" is open over the pages (Shell sets it): a trailer in the viewer pauses (RUY-802).
    property bool covered: false
}
