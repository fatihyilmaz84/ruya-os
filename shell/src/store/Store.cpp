#include "Store.h"

#include "DBusStoreBackend.h"
#include "MockStoreBackend.h"

#include <QHash>

#include <algorithm>

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
    connect(m_backend.get(), &StoreBackend::appLoaded, this, [this](const AppInfo &app) {
        if (app.newPermissions.isEmpty())
            m_added.remove(app.id);
        else
            m_added.insert(app.id, app.newPermissions);
        if (mergeDetails(m_catalogue, app))
            emit catalogueChanged();
        if (mergeDetails(m_results, app))
            emit resultsChanged();
        if (mergeDetails(m_installed, app))
            emit installedChanged();
        emit appLoaded(app.id);
    });
    connect(m_backend.get(), &StoreBackend::appLoadFailed, this, [this](const QString &id) { emit appLoadFailed(id); });
    connect(m_backend.get(), &StoreBackend::installedListed, this, [this](const QList<AppInfo> &apps) {
        // What an update adds is only known while the update is there.
        for (auto it = m_added.begin(); it != m_added.end();) {
            const QString id = it.key();
            const bool pending = std::any_of(apps.cbegin(), apps.cend(), [&id](const AppInfo &a) { return a.id == id && a.updateAvailable; });
            it = pending ? std::next(it) : m_added.erase(it);
        }
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
    connect(m_backend.get(), &StoreBackend::serviceLost, this, [this](const QStringList &appIds) {
        // A job of the lost service never finishes; do not show it for ever. Pages waiting for
        // its result get "failed" so that they stop working.
        QStringList ids = m_jobs.keys(); // running; a queued job has no progress yet
        for (const QString &id : appIds) {
            if (!ids.contains(id))
                ids.append(id);
        }
        if (!m_jobs.isEmpty()) {
            m_jobs.clear();
            emit jobsChanged();
        }
        for (const QString &id : ids) {
            m_lost.insert(id);
            emit jobFinished(id, QStringLiteral("failed"));
        }
    });
    connect(m_backend.get(), &StoreBackend::jobsListed, this, [this](const QList<StoreJob> &jobs) {
        // The table is the truth: it replaces what was shown, which may be stale.
        QVariantMap running;
        for (const StoreJob &j : jobs) {
            if (j.state == QLatin1String("running"))
                running.insert(j.appId, QVariantMap{{QStringLiteral("percent"), int(j.percent)}, {QStringLiteral("phase"), j.phase}});
        }
        if (running != m_jobs) {
            m_jobs = running;
            emit jobsChanged();
        }
        // An app whose job was given up as failed may have a different result: Flatpak finished
        // it, or it failed for another reason. What is "failed" already needs no second word.
        for (const QString &app : std::as_const(m_lost)) {
            const StoreJob *last = nullptr;
            for (const StoreJob &j : jobs) {
                if (j.appId == app)
                    last = &j;
            }
            if (last && last->state == QLatin1String("finished") && last->status != QLatin1String("failed"))
                emit jobFinished(app, last->status);
        }
        m_lost.clear();
        emit jobsReconciled();
    });
    m_backend->refresh();
    m_backend->search(QString(), false, 0);
    m_backend->listJobs();
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

QVariantList Store::toList(const QList<AppInfo> &apps) const
{
    QVariantList out;
    for (AppInfo a : apps) {
        // The lists never carry what an update adds; GetApp did, and the page still needs it.
        if (a.updateAvailable && a.newPermissions.isEmpty())
            a.newPermissions = m_added.value(a.id);
        out.append(a.toVariant());
    }
    return out;
}

bool Store::mergeDetails(QVariantList &list, const AppInfo &app) const
{
    for (QVariant &v : list) {
        QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("id")).toString() != app.id)
            continue;
        if (m.value(QStringLiteral("permissions")).toStringList() == app.permissions
            && m.value(QStringLiteral("newPermissions")).toStringList() == app.newPermissions)
            return false;
        m.insert(QStringLiteral("permissions"), app.permissions);
        m.insert(QStringLiteral("newPermissions"), app.newPermissions);
        v = m;
        return true;
    }
    return false;
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
        const QStringList added = update ? m_added.value(m.value(QStringLiteral("id")).toString()) : QStringList();
        if (m.value(QStringLiteral("installed")).toBool() == isInstalled
            && m.value(QStringLiteral("updateAvailable")).toBool() == update
            && m.value(QStringLiteral("newPermissions")).toStringList() == added)
            continue;
        m.insert(QStringLiteral("installed"), isInstalled);
        m.insert(QStringLiteral("updateAvailable"), update);
        m.insert(QStringLiteral("newPermissions"), added);
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

void Store::loadApp(const QString &appId)
{
    m_backend->getApp(appId);
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
    auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get());
    if (!mock)
        return;
    mock->reset();
    m_lost.clear();
    // The reset drops the mock's running jobs without a JobFinished, so the jobs this facade
    // already saw progress for would stay in `jobs` for ever (T-167).
    if (!m_jobs.isEmpty()) {
        m_jobs.clear();
        emit jobsChanged();
    }
}

void Store::mockServiceLost()
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->loseService();
}

void Store::mockServiceRegained(const QStringList &finishedApps)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->regainService(finishedApps);
}

void Store::mockForgetJobs()
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->forgetJobs();
}

void Store::mockListJobsDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->listJobsDelayed(ms);
}

int Store::mockPendingJobLists() const
{
    auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get());
    return mock ? mock->pendingJobLists() : 0;
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
