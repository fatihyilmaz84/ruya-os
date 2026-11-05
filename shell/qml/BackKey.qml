pragma Singleton
import QtQuick

// The one definition of "this key is Back (B)". Every page, pane and dialog asks here instead of
// listing keys. The controller sends Key_Back or Key_Escape (B), a keyboard Esc or Backspace.
QtObject {
    // Controller B or keyboard Esc. Text fields (TextEntry, PinPad, the OSK) use only this one:
    // for them Backspace deletes a character.
    function isBack(key) {
        return key === Qt.Key_Escape || key === Qt.Key_Back
    }

    // Everywhere else Backspace is Back too (docs/specs/02-shell.md section 4.2).
    function isBackOrBackspace(key) {
        return isBack(key) || key === Qt.Key_Backspace
    }
}
