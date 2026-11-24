pragma Singleton
import QtQuick

// Where an item lies in one of its ancestors: the sum of the x and y of every item from it up to (not including) the
// ancestor. A binding that calls it follows each of them moving (a Row placing its children, a tray growing). The one
// parent walk of the top bar's inks (TopBarInk.span), the section nav's pills and the focus glide.
QtObject {
    // The offset of `item` in `ancestor` as a point, or null when `item` is not under it (or not parented yet).
    function of(item, ancestor) {
        if (!item || !ancestor)
            return null
        let x = 0
        let y = 0
        for (let i = item; i !== ancestor; i = i.parent) {
            if (!i)
                return null
            x += i.x
            y += i.y
        }
        return Qt.point(x, y)
    }
}
