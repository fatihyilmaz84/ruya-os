#include "Store.h"

#include "DBusStoreBackend.h"
#include "MockStoreBackend.h"

#include <QHash>

Store::Store(std::unique_ptr<StoreBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &StoreBackend::searchFinished, this, [this](const QString &query, bool gamepadOnly, const QList<AppInfo> &apps) {
        const QVariantList list = toList(apps);
        if (!m_available) {
            m_available = true;
            emit availableChanged();
        }
        const bool wanted = query == m_lastQuery && gamepadOnly == m_gamepadOnly;
        if (query.isEmpty() && !gamepadOnly) {
            m_catalogue = list;
            emit catalogueChanged();
        }
        if (wanted) {
            m_results = list;
            emit resultsChanged();
            emit searchFinished(query, list);
        }
    });
    connect(m_backend.get(), &StoreBackend::installedListed, this, [this](const QList<AppInfo> &apps) {
        m_installed = toList(apps);
        emit installedChanged();
        // The apps already held keep their records: only their flags follow the installed set.
        if (patchFlags(m_catalogue))
            emit catalogueChanged();
        if (patchFlags(m_results))
            emit resultsChanged();
    });
    connect(m_backend.get(), &StoreBackend::installedChanged, this, [this] {
        m_backend->refresh(); // not the catalogue: its records are patched when the list arrives
    });
    connect(m_backend.get(), &StoreBackend::catalogChanged, this, [this] {
        m_backend->search(QString(), false, 0);
        if (!m_lastQuery.isEmpty() || m_gamepadOnly)
            m_backend->search(m_lastQuery, m_gamepadOnly, 0);
    });
    connect(m_backend.get(), &StoreBackend::jobProgress, this, [this](const QString &id, int percent, const QString &phase) {
        m_jobs.insert(id, QVariantMap{{QStringLiteral("percent"), percent}, {QStringLiteral("phase"), phase}});
        emit jobsChanged();
    });
    connect(m_backend.get(), &StoreBackend::jobFinished, this, [this](const QString &id, const QString &status) {
        if (m_jobs.remove(id))
            emit jobsChanged();
        emit jobFinished(id, status);
    });
    m_backend->refresh();
    m_backend->search(QString(), false, 0);
}

Store::~Store() = default;

Store *Store::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<StoreBackend> backend;
    // Like Audio and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockStoreBackend>();
    else
        backend = std::make_unique<DBusStoreBackend>();
    return new Store(std::move(backend));
}

QVariantList Store::toList(const QList<AppInfo> &apps)
{
    QVariantList out;
    for (const AppInfo &a : apps)
        out.append(a.toVariant());
    return out;
}

void Store::search(const QString &query)
{
    m_lastQuery = query;
    m_backend->search(query, m_gamepadOnly, 0);
}

void Store::setControllerFilter(const QString &filter)
{
    const bool gamepadOnly = filter == QLatin1String("gamepad");
    if (gamepadOnly == m_gamepadOnly)
        return;
    m_gamepadOnly = gamepadOnly;
    emit controllerFilterChanged();
    m_backend->search(m_lastQuery, m_gamepadOnly, 0);
}

bool Store::patchFlags(QVariantList &list) const
{
    QHash<QString, bool> installed; // id -> update available
    for (const QVariant &v : m_installed) {
        const QVariantMap m = v.toMap();
        installed.insert(m.value(QStringLiteral("id")).toString(), m.value(QStringLiteral("updateAvailable")).toBool());
    }
    bool changed = false;
    for (QVariant &v : list) {
        QVariantMap m = v.toMap();
        const auto it = installed.constFind(m.value(QStringLiteral("id")).toString());
        const bool isInstalled = it != installed.cend();
        const bool update = isInstalled && it.value();
        if (m.value(QStringLiteral("installed")).toBool() == isInstalled
            && m.value(QStringLiteral("updateAvailable")).toBool() == update)
            continue;
        m.insert(QStringLiteral("installed"), isInstalled);
        m.insert(QStringLiteral("updateAvailable"), update);
        v = m;
        changed = true;
    }
    return changed;
}

void Store::install(const QString &appId)
{
    m_backend->install(appId);
}

void Store::uninstall(const QString &appId, bool deleteData)
{
    m_backend->uninstall(appId, deleteData);
}

void Store::update(const QString &appId)
{
    m_backend->update(appId);
}

QVariantMap Store::app(const QString &appId) const
{
    for (const QVariant &v : m_catalogue) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("id")).toString() == appId)
            return m;
    }
    return {};
}

bool Store::mockDataDeleted(const QString &appId) const
{
    auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get());
    return mock && mock->dataDeleted(appId);
}

void Store::mockReset()
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->reset();
}

int Store::mockSearchCount() const
{
    auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get());
    return mock ? mock->searchCount() : 0;
}

void Store::mockCatalogChanged()
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->announceCatalogChanged();
}
