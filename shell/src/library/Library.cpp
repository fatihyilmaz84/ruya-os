#include "Library.h"

#include "DBusLibraryBackend.h"
#include "MockLibraryBackend.h"

#include <algorithm>

namespace {
constexpr int RecentCount = 8;
}

Library::Library(std::unique_ptr<LibraryBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &LibraryBackend::itemsListed, this, [this](const QList<LibraryItem> &items) {
        // The contract orders by last played; sort again so the facade does not depend on it.
        QList<LibraryItem> sorted = items;
        std::stable_sort(sorted.begin(), sorted.end(),
                         [](const LibraryItem &a, const LibraryItem &b) { return a.lastPlayed > b.lastPlayed; });
        m_items.clear();
        m_games.clear();
        m_recent.clear();
        for (const LibraryItem &i : std::as_const(sorted)) {
            const QVariantMap v = i.toVariant();
            m_items.append(v);
            if (i.kind == QLatin1String("game"))
                m_games.append(v);
            if (i.lastPlayed > 0 && m_recent.size() < RecentCount)
                m_recent.append(v);
        }
        if (!m_available) {
            m_available = true;
            emit availableChanged();
        }
        emit itemsChanged();
    });
    connect(m_backend.get(), &LibraryBackend::itemsChanged, this, [this] { m_backend->listItems(); });
    connect(m_backend.get(), &LibraryBackend::rescanFinished, this, &Library::rescanned);
    m_backend->listItems();
}

Library::~Library() = default;

Library *Library::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<LibraryBackend> backend;
    // Like Store and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockLibraryBackend>();
    else
        backend = std::make_unique<DBusLibraryBackend>();
    return new Library(std::move(backend));
}

void Library::rescan()
{
    m_backend->rescan();
}

void Library::launch(const QString &id)
{
    const QVariantMap found = item(id);
    if (found.isEmpty()) {
        qWarning("ruya-shell: Library.launch: unknown item %s", qPrintable(id));
        return;
    }
    emit launchRequested(id, found.value(QStringLiteral("launch")).toString());
}

QString Library::sessionAppId(const QString &id) const
{
    const QString prefix = QStringLiteral("flatpak:");
    const QString spec = item(id).value(QStringLiteral("launch")).toString();
    return spec.startsWith(prefix) ? spec.mid(prefix.size()) : QString();
}

QVariantMap Library::item(const QString &id) const
{
    for (const QVariant &v : m_items) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("id")).toString() == id)
            return m;
    }
    return {};
}

void Library::resetMockForTests(const QString &scenario)
{
    if (auto *mock = qobject_cast<MockLibraryBackend *>(m_backend.get()))
        mock->reset(scenario);
}

void Library::mockListDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockLibraryBackend *>(m_backend.get()))
        mock->listItemsDelayed(ms);
}

int Library::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockLibraryBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
