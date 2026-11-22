#include "MockLibraryBackend.h"
#include "MockArt.h"

#include <algorithm>

#include <QRegularExpression>
#include <QTimer>

namespace {
// Steam items are per profile (ADR-045). The mock's three profiles (Player One, Ada, Sam) have the default
// Steam games, which the shell's tests sign in for, and so does nobody (""), for the tests that build a page
// without a signed-in Shell; a profile made later (p4 on) has none. (The service lists none for nobody.)
bool hasSteamGames(const QString &profile)
{
    static const QStringList profiles = {QString(), QStringLiteral("p1"), QStringLiteral("p2"), QStringLiteral("p3")};
    return profiles.contains(profile);
}

LibraryItem item(const char *id, const char *kind, const char *title, qlonglong lastPlayed)
{
    LibraryItem i;
    i.id = QString::fromLatin1(id);
    i.kind = QString::fromLatin1(kind);
    i.title = QString::fromLatin1(title);
    i.source = i.id.startsWith(QLatin1String("steam:")) ? QStringLiteral("steam") : QStringLiteral("flatpak");
    const QString key = i.id.mid(i.id.indexOf(QLatin1Char(':')) + 1);
    i.launch = i.source == QLatin1String("steam") ? QStringLiteral("steam://rungameid/") + key
                                                  : QStringLiteral("flatpak:") + key;
    i.lastPlayed = lastPlayed;
    return i;
}

// The contract's order: last played descending, then title (case-insensitive), then id.
bool before(const LibraryItem &a, const LibraryItem &b)
{
    if (a.lastPlayed != b.lastPlayed)
        return a.lastPlayed > b.lastPlayed;
    const int t = a.title.compare(b.title, Qt::CaseInsensitive);
    return t != 0 ? t < 0 : a.id < b.id;
}

// A resolution that found a runner.
LibraryResolution resolved(const char *runner, const char *source, const char *tested)
{
    LibraryResolution r;
    r.runner = QString::fromLatin1(runner);
    r.runnerSource = QString::fromLatin1(source);
    r.runnerTested = QString::fromLatin1(tested);
    return r;
}
} // namespace

namespace {
QList<MockLibraryBackend *> &liveBackends()
{
    static QList<MockLibraryBackend *> list;
    return list;
}
} // namespace

MockLibraryBackend::~MockLibraryBackend()
{
    liveBackends().removeAll(this);
}

void MockLibraryBackend::flatpakUninstalled(const QString &appId)
{
    for (MockLibraryBackend *b : std::as_const(liveBackends()))
        b->removeItem(QStringLiteral("flatpak:") + appId);
}

// The runners image/play/runners/ pins (ProtonGE11, Wine11: their runner.json), as Library1
// ListRunners lists them (folder name order).
QList<LibraryRunner> pinnedRunners()
{
    LibraryRunner proton;
    proton.family = QStringLiteral("proton-ge");
    proton.kind = QStringLiteral("proton");
    proton.version = QStringLiteral("GE-Proton11-12");
    proton.licence = QStringLiteral("BSD-3-Clause AND LGPL-2.1-or-later AND LGPL-2.0-or-later AND Zlib AND MIT AND OFL-1.1");
    proton.sourceUrl = QStringLiteral("https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton11-12");
    LibraryRunner wine;
    wine.family = QStringLiteral("wine");
    wine.kind = QStringLiteral("wine");
    wine.version = QStringLiteral("wine-11.0");
    wine.licence = QStringLiteral("LGPL-2.1-or-later AND LGPL-2.1-only AND BSD-3-Clause AND BSD-2-Clause AND NCSA AND MIT "
                                  "AND Zlib AND IJG AND libpng-2.0 AND libtiff AND OLDAP-2.8 AND TU-Berlin-1.0 AND WTFPL");
    wine.sourceUrl = QStringLiteral("https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz");
    return {proton, wine};
}

MockLibraryBackend::MockLibraryBackend(QObject *parent)
    : LibraryBackend(parent)
{
    liveBackends().append(this);
    reset(QString());
}

void MockLibraryBackend::listRunners()
{
    listRunnersDelayed(0);
}

void MockLibraryBackend::listRunnersDelayed(int ms)
{
    const quint64 request = beginRunnersRequest();
    ++m_pending;
    QTimer::singleShot(ms, this, [this, request, snapshot = m_runners] {
        --m_pending;
        deliverRunners(request, snapshot);
    });
}

QString MockLibraryBackend::choiceStatus(const QString &profile, const QString &id) const
{
    static const QRegularExpression profileId(QStringLiteral("^[A-Za-z0-9_-]{1,32}$"));
    if (!profileId.match(profile).hasMatch())
        return QStringLiteral("invalid");
    for (const LibraryItem &i : m_items) {
        if (i.id == id)
            return i.play ? QStringLiteral("ok") : QStringLiteral("not_play");
    }
    return QStringLiteral("unknown");
}

namespace {
bool knownChoice(const QString &choice)
{
    return choice == QLatin1String("package") || choice == QLatin1String("bundled") || choice == QLatin1String("system");
}
} // namespace

void MockLibraryBackend::getRunnerChoice(const QString &profile, const QString &id)
{
    const QString status = m_failing.contains(QLatin1String("get")) ? QStringLiteral("failed") : choiceStatus(profile, id);
    const QString choice = status == QLatin1String("ok") ? m_choices.value(profile).value(id, QStringLiteral("package")) : QString();
    QTimer::singleShot(0, this, [this, profile, id, status, choice] { emit runnerChoiceAnswered(profile, id, status, choice); });
}

void MockLibraryBackend::setRunnerChoice(const QString &profile, const QString &id, const QString &choice)
{
    const QString status = m_failing.contains(QLatin1String("set")) ? QStringLiteral("failed")
                           : knownChoice(choice)                    ? choiceStatus(profile, id)
                                                                    : QStringLiteral("invalid");
    bool changed = false;
    if (status == QLatin1String("ok")) {
        const QString before = m_choices.value(profile).value(id, QStringLiteral("package"));
        changed = before != choice;
        if (choice == QLatin1String("package")) {
            m_choices[profile].remove(id);
            if (m_choices.value(profile).isEmpty())
                m_choices.remove(profile);
        } else {
            m_choices[profile].insert(id, choice);
        }
    }
    QTimer::singleShot(0, this, [this, profile, id, choice, status, changed] {
        if (changed)
            emit runnerChoiceChanged(profile, id, choice);
        emit runnerChoiceSet(profile, id, choice, status);
    });
}

void MockLibraryBackend::resolveRunner(const QString &id, const QString &choice)
{
    // Profile-free: a valid stand-in profile id, so only the id and the choice decide.
    const QString status = m_failing.contains(QLatin1String("resolve")) ? QStringLiteral("failed")
                           : knownChoice(choice) ? choiceStatus(QStringLiteral("mock"), id)
                                                 : QStringLiteral("invalid");
    LibraryResolution resolution;
    if (status == QLatin1String("ok")) {
        const auto table = m_resolutions.constFind(id);
        if (table != m_resolutions.constEnd() && table->contains(choice)) {
            resolution = table->value(choice);
        } else {
            for (const LibraryItem &i : std::as_const(m_items)) {
                if (i.id == id)
                    resolution = i.resolution;
            }
        }
    }
    QTimer::singleShot(0, this, [this, id, choice, status, resolution] { emit runnerResolved(id, choice, status, resolution); });
}

void MockLibraryBackend::setResolution(const QString &id, const QString &choice, const LibraryResolution &resolution)
{
    m_resolutions[id].insert(choice, resolution);
    if (choice != QLatin1String("package"))
        return;
    for (LibraryItem &i : m_items) {
        if (i.id == id)
            i.resolution = resolution;
    }
    emit itemsChanged();
}

void MockLibraryBackend::reset(const QString &scenario)
{
    m_items.clear();
    // Every scenario has the image's pinned runner and no stored runner choice (RUY-959), and every
    // runner call answers (RUY-905).
    m_runners = pinnedRunners();
    m_choices.clear();
    m_resolutions.clear();
    m_failing.clear();
    listRunners();
    // "art:<dir>": the default library, each item with a picture from <dir> (tests only, T-281).
    const bool withArt = scenario.startsWith(QLatin1String("art:"));
    if (scenario != QLatin1String("empty")) {
        m_items = {
            // The newest is a Flatpak game: the Home hero offers Play only for items Session1 can
            // start (T-147), and most tests begin with Play focused.
            item("flatpak:org.example.Racer", "game", "Turbo Racer", 1761800000),
            item("steam:730", "game", "Counter Strike", 1761000000),
            item("steam:620", "game", "Portal 2", 1760500000),
            item("steam:440", "game", "Team Fortress", 1759000000),
            item("flatpak:org.example.Puzzle", "game", "Block Puzzle", 1758000000),
            item("steam:105600", "game", "Terraria", 1757000000),
            item("flatpak:org.example.Platformer", "game", "Pixel Hopper", 1755000000),
            item("steam:367520", "game", "Hollow Knight", 1750000000),
            item("flatpak:org.example.Player", "app", "Open Player", 1760000000),
            item("flatpak:org.example.Browser", "app", "Web Browser", 0),
        };
        // "unlisted": one more Flatpak app that the Store's catalogue does not know (RUY-16: no Details row).
        if (scenario == QLatin1String("unlisted"))
            m_items.append(item("flatpak:org.example.Unlisted", "app", "Unlisted App", 1762000000));
        // "play": one .play app with every field and the image roles (RUY-852; the real art is on the VM). It
        // has no screenshots, preview or trailer: the mock ships no image or video for them (RUY-886); "playart:<dir>"
        // has them.
        // "playart:<dir>": the same app with real pictures from <dir> (tests and screenshots, RUY-856: logo.png,
        // card/cover/hero/icon from the glow fixtures, the trailer's file does not exist so the trailer cannot play),
        // plus an icon-only .play app and a Flatpak that is not a .play but carries a logo and a trailer key
        // (it must never show a trust badge or a signer).
        const bool playArt = scenario.startsWith(QLatin1String("playart:"));
        if (scenario == QLatin1String("play") || playArt) {
            LibraryItem p = item("flatpak:play.com.example.starhopper", "game", "Star Hopper", 1762100000);
            // Pictures the shell ships (the bundled wallpapers): a mock path must name a file that exists, or the
            // item draws "cannot load" (RUY-886). No preview or trailer: the mock ships no video.
            const QString bundled = QStringLiteral("qrc:/qt/qml/RuyaShell/assets/wallpapers/");
            p.art = {{QStringLiteral("icon"), bundled + QStringLiteral("ember.jpg")},
                     {QStringLiteral("logo"), bundled + QStringLiteral("orchid.jpg")},
                     {QStringLiteral("card"), bundled + QStringLiteral("dusk.jpg")},
                     {QStringLiteral("cover"), bundled + QStringLiteral("lagoon.jpg")},
                     {QStringLiteral("hero"), bundled + QStringLiteral("aurora.jpg")}};
            p.play = true;
            p.genres = {QStringLiteral("platformer"), QStringLiteral("adventure")};
            p.playersMin = 1;
            p.playersMax = 2;
            p.controller = QStringLiteral("full");
            p.ageRating = {{QStringLiteral("violence-cartoon"), QStringLiteral("mild")}};
            p.playTier = QStringLiteral("developer");
            p.playSigner = QStringLiteral("Example Games");
            p.playSignerKeyId = QStringLiteral("0123456789abcdef0123456789abcdef");
            // A Windows game on Proton with a bundled GE-Proton10-9, the version its developer tested, and
            // source "newest": the image's GE-Proton11-12 runs it (RUY-903). Bundled is its own copy, System
            // the image's: what the launcher answers such a package against the pinned runners (RUY-905).
            const LibraryResolution imageProton = resolved("proton-ge GE-Proton11-12", "system", "GE-Proton10-9");
            p.resolution = imageProton;
            m_resolutions[p.id] = {{QStringLiteral("package"), imageProton},
                                   {QStringLiteral("bundled"), resolved("proton-ge GE-Proton10-9", "bundled", "GE-Proton10-9")},
                                   {QStringLiteral("system"), imageProton}};
            if (playArt) {
                const QString dir = scenario.mid(8);
                auto at = [&](const char *name) { return dir + QLatin1Char('/') + QLatin1String(name) + QStringLiteral(".png"); };
                p.art = {{QStringLiteral("icon"), at("green")},
                         {QStringLiteral("logo"), at("logo")},
                         {QStringLiteral("card"), at("playcard")},
                         {QStringLiteral("cover"), at("playcover")},
                         {QStringLiteral("hero"), at("playhero")},
                         {QStringLiteral("trailer"), QStringLiteral("/mock/play/trailer.webm")}};
                p.playScreenshots = {at("playhero"), at("playcover"), at("playcard")};
                LibraryItem quiet = item("flatpak:play.com.example.quiet", "game", "Quiet Quest", 1762050000);
                quiet.art = {{QStringLiteral("icon"), at("pastel")}};
                quiet.play = true;
                // A Wine game for the image's runner only, needing Wine 12: the pinned wine-11.0 is too old and
                // there is no bundled copy, so every choice is the package default's refusal.
                quiet.resolution.resolveError = QStringLiteral("The OS runner is wine-11.0, older than the required 12.0.");
                quiet.resolution.resolveCode = QStringLiteral("resolve.system_too_old");
                m_items.append(quiet);
                LibraryItem odd = item("flatpak:org.example.Oddity", "game", "Oddity", 1762000000);
                odd.art = {{QStringLiteral("logo"), at("logo")}, {QStringLiteral("trailer"), QStringLiteral("/mock/play/trailer.webm")}};
                odd.playTier = QStringLiteral("official");      // never shown: `play` is false
                odd.playSigner = QStringLiteral("Not A Signer");
                m_items.append(odd);
            }
            m_items.append(p);
        }
        // "chess": Open Chess, installed with an update in the Store's mock, is in the library too (the game page's
        // update state, RUY-524).
        if (scenario == QLatin1String("chess"))
            m_items.append(item("flatpak:org.example.Chess", "game", "Open Chess", 1761900000));
        // "artroles:<dir>": two Flatpak games that carry one art role besides the icon, a card and a cover
        // (RUY-873: every surface must show them, not the generated art). Newest first, so Home's hero starts on them.
        if (scenario.startsWith(QLatin1String("artroles:"))) {
            const QString dir = scenario.mid(9);
            auto at = [&](const char *name) { return dir + QLatin1Char('/') + QLatin1String(name) + QStringLiteral(".png"); };
            LibraryItem cardOnly = item("flatpak:org.example.CardOnly", "game", "Card Only", 1762300000);
            cardOnly.art = {{QStringLiteral("icon"), at("pastel")}, {QStringLiteral("card"), at("playcard")}};
            LibraryItem coverOnly = item("flatpak:org.example.CoverOnly", "game", "Cover Only", 1762200000);
            coverOnly.art = {{QStringLiteral("icon"), at("pastel")}, {QStringLiteral("cover"), at("playcover")}};
            m_items.append(cardOnly);
            m_items.append(coverOnly);
        }
        if (withArt) {
            const QString dir = scenario.mid(4);
            for (int i = 0; i < m_items.size(); ++i) {
                m_items[i].art.insert(QStringLiteral("tile"), mockArtPath(dir, i));
                m_items[i].art.insert(QStringLiteral("icon"), mockArtPath(dir, i));
            }
        }
        // "unplayed": all installed, nothing started yet (a fresh image, Home's fallback row).
        if (scenario == QLatin1String("unplayed")) {
            for (LibraryItem &i : m_items)
                i.lastPlayed = 0;
        }
        std::sort(m_items.begin(), m_items.end(), before);
    }
    emit itemsChanged();
}

void MockLibraryBackend::removeItem(const QString &id)
{
    m_items.removeIf([&](const LibraryItem &i) { return i.id == id; });
    emit itemsChanged();
}

void MockLibraryBackend::listItems()
{
    listItemsDelayed(0);
}

QList<LibraryItem> MockLibraryBackend::visibleItems() const
{
    if (hasSteamGames(m_active))
        return m_items;
    QList<LibraryItem> out;
    for (const LibraryItem &i : m_items) {
        if (i.source != QLatin1String("steam"))
            out.append(i);
    }
    return out;
}

void MockLibraryBackend::profileSelected(const QString &profile)
{
    // As ruya-session: SetActiveProfile after the switch, then ItemsChanged when the list differs.
    QTimer::singleShot(0, this, [this, profile] {
        if (profile == m_active)
            return;
        const bool before = hasSteamGames(m_active);
        m_active = profile;
        emit activeProfileChanged(profile);
        if (before != hasSteamGames(m_active))
            emit itemsChanged();
    });
}

void MockLibraryBackend::listItemsDelayed(int ms)
{
    const quint64 request = beginListRequest();
    ++m_pending;
    QTimer::singleShot(ms, this, [this, request, snapshot = visibleItems()] {
        --m_pending;
        deliverList(request, snapshot);
    });
}

void MockLibraryBackend::rescan()
{
    QTimer::singleShot(0, this, [this] { emit rescanFinished(); });
}
