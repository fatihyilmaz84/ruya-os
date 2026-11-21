pragma Singleton
import QtQuick
import RuyaShell

// What an installed app is called on the settings and game pages (RUY-854): a .play game by the title of its
// package (the Library item whose Flatpak it is; the Store only knows the id's last part), any other app by the
// Store's installed name. One rule for Settings -> Privacy, the permissions page and the game page's title.
QtObject {
    // "" when nobody knows the app. A binding that calls it follows the Library list and the Store's installed list.
    function of(appId) {
        const item = Library.items.length >= 0 ? Library.itemForApp(appId) : ({})
        if (item.play === true && (item.title ?? "") !== "")
            return item.title
        return (Store.installed.find(a => a.id === appId) ?? {}).name ?? ""
    }
}
