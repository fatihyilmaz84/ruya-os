#include "Store.h"

#include "DBusStoreBackend.h"
#include "MockStoreBackend.h"

Store::Store(std::unique_ptr<StoreBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &StoreBackend::searchFinished, this, [this](const QString &query, const QList<AppInfo> &apps) {
        const QVariantList list = toList(apps);
        if (!m_available) {
            m_available = true;
            emit availableChanged();
        }
        if (query.isEmpty()) {
            m_catalogue = list;
            emit catalogueChanged();
        }
        m_results = list;
        emit resultsChanged();
        emit searchFinished(query, list);
    });
    connect(m_backend.get(), &StoreBackend::installedListed, this, [this](const QList<AppInfo> &apps) {
        m_installed = toList(apps);
        emit installedChanged();
    });
    connect(m_backend.get(), &StoreBackend::installedChanged, this, [this] {
        // The flags in the catalogue go stale with the installed set: read both again.
        m_backend->refresh();
        m_backend->search(QString());
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
    m_backend->search(QString());
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
    m_backend->search(query);
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
