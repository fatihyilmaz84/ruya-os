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
    connect(m_backend.get(), &LibraryBackend::runnersListed, this, [this](const QList<LibraryRunner> &runners) {
        m_runners.clear();
        for (const LibraryRunner &r : runners)
            m_runners.append(r.toVariant());
        emit runnersChanged();
    });
    // The choice answers are the signed-in profile's: one asked for (or changed for) a profile that is not
    // in front any more is dropped, as NotificationCentre drops another profile's list.
    connect(m_backend.get(), &LibraryBackend::runnerChoiceAnswered, this,
            [this](const QString &profile, const QString &id, const QString &status, const QString &choice) {
                if (profile == m_profile)
                    emit runnerChoiceAnswered(id, status, choice);
            });
    connect(m_backend.get(), &LibraryBackend::runnerChoiceSet, this,
            [this](const QString &profile, const QString &id, const QString &choice, const QString &status) {
                if (profile == m_profile)
                    emit runnerChoiceSet(id, choice, status);
            });
    connect(m_backend.get(), &LibraryBackend::runnerChoiceChanged, this,
            [this](const QString &profile, const QString &id, const QString &choice) {
                if (profile == m_profile && !m_profile.isEmpty())
                    emit runnerChoiceChanged(id, choice);
            });
    connect(m_backend.get(), &LibraryBackend::runnerResolved, this,
            [this](const QString &id, const QString &choice, const QString &status, const LibraryResolution &r) {
                emit runnerResolved(id, choice, status, r.toVariant());
            });
    m_backend->listItems();
    m_backend->listRunners();
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

void Library::setProfile(const QString &profile)
{
    if (profile == m_profile)
        return;
    m_profile = profile;
    emit profileChanged();
}

void Library::runnerChoice(const QString &id)
{
    m_backend->getRunnerChoice(m_profile, id);
}

void Library::setRunnerChoice(const QString &id, const QString &choice)
{
    m_backend->setRunnerChoice(m_profile, id, choice);
}

void Library::mockSetResolution(const QString &id, const QString &choice, const QVariantMap &resolution)
{
    auto *mock = qobject_cast<MockLibraryBackend *>(m_backend.get());
    if (!mock)
        return;
    mock->setResolution(id, choice, LibraryResolution::fromVariant(resolution));
}

void Library::mockFailRunnerCalls(const QStringList &calls)
{
    if (auto *mock = qobject_cast<MockLibraryBackend *>(m_backend.get()))
        mock->setFailingRunnerCalls(calls);
}

void Library::resolveRunner(const QString &id, const QString &choice)
{
    m_backend->resolveRunner(id, choice);
}

void Library::mockSetRunners(const QVariantList &runners, int ms)
{
    auto *mock = qobject_cast<MockLibraryBackend *>(m_backend.get());
    if (!mock)
        return;
    QList<LibraryRunner> list;
    for (const QVariant &v : runners) {
        const QVariantMap m = v.toMap();
        LibraryRunner r;
        r.family = m.value(QStringLiteral("family")).toString();
        r.kind = m.value(QStringLiteral("kind")).toString();
        r.version = m.value(QStringLiteral("version")).toString();
        r.licence = m.value(QStringLiteral("licence")).toString();
        r.sourceUrl = m.value(QStringLiteral("sourceUrl")).toString();
        list.append(r);
    }
    mock->setRunners(list);
    mock->listRunnersDelayed(ms);
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

// The Flatpak application id an item starts ("flatpak:<id>" in its launch spec), or "".
static QString flatpakIdOf(const QVariantMap &item)
{
    const QString prefix = QStringLiteral("flatpak:");
    const QString spec = item.value(QStringLiteral("launch")).toString();
    return spec.startsWith(prefix) ? spec.mid(prefix.size()) : QString();
}

QString Library::sessionAppId(const QString &id) const
{
    return flatpakIdOf(item(id));
}

QVariantMap Library::itemForApp(const QString &appId) const
{
    if (appId.isEmpty())
        return {};
    for (const QVariant &v : m_items) {
        const QVariantMap m = v.toMap();
        if (flatpakIdOf(m) == appId)
            return m;
    }
    return {};
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

void Library::mockRemoveItem(const QString &id)
{
    if (auto *mock = qobject_cast<MockLibraryBackend *>(m_backend.get()))
        mock->removeItem(id);
}

int Library::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockLibraryBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
