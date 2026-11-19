pragma Singleton
import QtQuick

// Which of a Library item's art roles a surface draws (RUY-873, 04 art): one rule, so a .play app that ships
// only a card or a cover shows that picture everywhere and not its icon. `art` is the item's art map (hero,
// tile, card, cover, ...; RUY-856) and may be null or undefined. An empty string counts as absent (`||`, not
// `??`), and the result is "" when no role has a picture.
//
//   wide(art)  hero, card, cover, tile: the surfaces wider than tall. The launch splash and the close card,
//              the quick menu's picture, the app page's header, the Home hero and the screen saver (which
//              also keeps only the apps for which this is not "").
//   tile(art)  tile, card, cover, hero: the cards. The games grid, the Home Recent row and the Hub's
//              running strip.
//
// The install sheets read the Inspect record of a package that is not installed yet (its `icon` is the
// designed last fallback) and do not use this.
QtObject {
    function wide(art) {
        return art ? (art.hero || art.card || art.cover || art.tile || "") : ""
    }

    function tile(art) {
        return art ? (art.tile || art.card || art.cover || art.hero || "") : ""
    }
}
