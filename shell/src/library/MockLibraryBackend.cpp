#include "MockLibraryBackend.h"

#include <algorithm>

#include <QTimer>

namespace {
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
} // namespace

MockLibraryBackend::MockLibraryBackend(QObject *parent)
    : LibraryBackend(parent)
{
    reset(QString());
}

void MockLibraryBackend::reset(const QString &scenario)
{
    m_items.clear();
    if (scenario != QLatin1String("empty")) {
        m_items = {
            item("steam:620", "game", "Portal 2", 1761800000),
            item("steam:730", "game", "Counter Strike", 1761000000),
            item("flatpak:org.example.Racer", "game", "Turbo Racer", 1760500000),
            item("steam:440", "game", "Team Fortress", 1759000000),
            item("flatpak:org.example.Puzzle", "game", "Block Puzzle", 1758000000),
            item("steam:105600", "game", "Terraria", 1757000000),
            item("flatpak:org.example.Platformer", "game", "Pixel Hopper", 1755000000),
            item("steam:367520", "game", "Hollow Knight", 1750000000),
            item("flatpak:org.example.Player", "app", "Open Player", 1760000000),
            item("flatpak:org.example.Browser", "app", "Web Browser", 0),
        };
        // "unplayed": all installed, nothing started yet (a fresh image, Home's fallback row).
        if (scenario == QLatin1String("unplayed")) {
            for (LibraryItem &i : m_items)
                i.lastPlayed = 0;
        }
        std::sort(m_items.begin(), m_items.end(), before);
    }
    emit itemsChanged();
}

void MockLibraryBackend::listItems()
{
    listItemsDelayed(0);
}

void MockLibraryBackend::listItemsDelayed(int ms)
{
    const quint64 request = beginListRequest();
    ++m_pending;
    QTimer::singleShot(ms, this, [this, request, snapshot = m_items] {
        --m_pending;
        deliverList(request, snapshot);
    });
}

void MockLibraryBackend::rescan()
{
    QTimer::singleShot(0, this, [this] { emit rescanFinished(); });
}
