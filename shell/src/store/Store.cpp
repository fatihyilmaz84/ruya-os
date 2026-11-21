#include "Store.h"

#include "DBusStoreBackend.h"
#include "MockStoreBackend.h"

#include <QHash>

#include <algorithm>
#include <utility>

Store::Store(std::unique_ptr<StoreBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &StoreBackend::searchFinished, this, [this](const QString &query, bool gamepadOnly, const QList<AppInfo> &apps) {
        const QVariantList list = toList(apps);
        setAvailable(true);
        const bool wanted = query == m_lastQuery && gamepadOnly == m_gamepadOnly;
        if (query.isEmpty() && !gamepadOnly) {
            m_catalogue = list;
            indexCatalogue();
            emit catalogueChanged();
        }
        if (wanted) {
            m_results = list;
            emit resultsChanged();
            emit searchFinished(query, list);
        }
    });
    connect(m_backend.get(), &StoreBackend::appLoaded, this, [this](const AppInfo &app) {
        m_getOnly.insert(app.id, QVariantMap{{QStringLiteral("screenshots"), app.screenshots}, {QStringLiteral("releaseNotes"), app.releaseNotes}});
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
        setAvailable(true);
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
        m_lost.remove(id); // a job after the lost one: the lost one is history
        m_jobs.insert(id, QVariantMap{{QStringLiteral("percent"), percent}, {QStringLiteral("phase"), phase}});
        emit jobsChanged();
    });
    connect(m_backend.get(), &StoreBackend::jobFinished, this, [this](const QString &id, const QString &status) {
        m_lost.remove(id);
        if (m_jobs.remove(id))
            emit jobsChanged();
        emit jobFinished(id, status);
    });
    connect(m_backend.get(), &StoreBackend::serviceLost, this, [this](const QHash<QString, QString> &jobApps) {
        setAvailable(false); // until it answers a list again (the Options menu leaves out its rows meanwhile)
        // A job of the lost service never finishes; do not show it for ever. Pages waiting for
        // its result get "failed" so that they stop working.
        QStringList ids = m_jobs.keys(); // running; a queued job has no progress yet
        for (const QString &id : jobApps) {
            if (!ids.contains(id))
                ids.append(id);
        }
        if (!m_jobs.isEmpty()) {
            m_jobs.clear();
            emit jobsChanged();
        }
        // The job by its id: its app may get others. key() assumes one tracked job per app, which
        // holds because the service refuses a second job of an app with "busy".
        for (const QString &id : ids)
            m_lost.insert(id, jobApps.key(id));
        for (const QString &id : ids)
            emit jobFinished(id, QStringLiteral("failed"));
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
        // it, or it failed for another reason. That job is found by its id (the app may have had
        // others since). What is "failed" already needs no second word.
        const QHash<QString, QString> lost = std::exchange(m_lost, {});
        for (auto it = lost.cbegin(); it != lost.cend(); ++it) {
            if (it.value().isEmpty())
                continue;
            const auto job = std::find_if(jobs.cbegin(), jobs.cend(), [&it](const StoreJob &j) { return j.id == it.value(); });
            if (job != jobs.cend() && job->state == QLatin1String("finished") && job->status != QLatin1String("failed"))
                emit jobFinished(it.key(), job->status);
        }
        emit jobsReconciled();
    });
    connect(m_backend.get(), &StoreBackend::permissionsLoaded, this,
            [this](const QString &id, const QString &status, const QStringList &effective, const QStringList &withdrawn,
                   const QStringList &withdrawable) {
        m_permissions.insert(id, QVariantMap{{QStringLiteral("status"), status},
                                             {QStringLiteral("effective"), effective},
                                             {QStringLiteral("withdrawn"), withdrawn},
                                             {QStringLiteral("withdrawable"), withdrawable}});
        emit permissionsLoaded(id);
    });
    connect(m_backend.get(), &StoreBackend::permissionChanged, this, [this](const QString &id, const QString &key, const QString &status) {
        emit permissionChanged(id, key, status);
        // The override is the record: read it again, whatever the answer was (a failure may have written half).
        m_backend->getPermissions(id);
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
        QVariantMap m = a.toVariant();
        const auto kept = m_getOnly.constFind(a.id);
        if (kept != m_getOnly.cend()) {
            m.insert(QStringLiteral("screenshots"), kept->value(QStringLiteral("screenshots")));
            m.insert(QStringLiteral("releaseNotes"), kept->value(QStringLiteral("releaseNotes")));
        }
        out.append(m);
    }
    return out;
}

bool Store::mergeDetails(QVariantList &list, const AppInfo &app) const
{
    for (QVariant &v : list) {
        QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("id")).toString() != app.id)
            continue;
        // What getApp reads beyond the lists: permissions, what an update adds, the screenshots
        // and the release notes (the other new keys the lists carry too, but a list may be older).
        const QVariantMap detail = app.toVariant();
        bool changed = false;
        for (const char *key : {"permissions", "newPermissions", "screenshots", "releaseNotes", "version", "releaseDate",
                                "installedVersion", "downloadSize", "license", "categories"}) {
            const QString k = QString::fromLatin1(key);
            if (m.value(k) != detail.value(k)) {
                m.insert(k, detail.value(k));
                changed = true;
            }
        }
        if (!changed)
            return false;
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

void Store::setAvailable(bool available)
{
    if (m_available == available)
        return;
    m_available = available;
    emit availableChanged();
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
    QHash<QString, QString> versions; // id -> installed version
    for (const QVariant &v : m_installed) {
        const QVariantMap m = v.toMap();
        installed.insert(m.value(QStringLiteral("id")).toString(), m.value(QStringLiteral("updateAvailable")).toBool());
        versions.insert(m.value(QStringLiteral("id")).toString(), m.value(QStringLiteral("installedVersion")).toString());
    }
    bool changed = false;
    for (QVariant &v : list) {
        QVariantMap m = v.toMap();
        const auto it = installed.constFind(m.value(QStringLiteral("id")).toString());
        const bool isInstalled = it != installed.cend();
        const bool update = isInstalled && it.value();
        const QStringList added = update ? m_added.value(m.value(QStringLiteral("id")).toString()) : QStringList();
        const QString version = isInstalled ? versions.value(m.value(QStringLiteral("id")).toString()) : QString();
        if (m.value(QStringLiteral("installed")).toBool() == isInstalled
            && m.value(QStringLiteral("updateAvailable")).toBool() == update
            && m.value(QStringLiteral("newPermissions")).toStringList() == added
            && m.value(QStringLiteral("installedVersion")).toString() == version)
            continue;
        m.insert(QStringLiteral("installed"), isInstalled);
        m.insert(QStringLiteral("updateAvailable"), update);
        m.insert(QStringLiteral("newPermissions"), added);
        m.insert(QStringLiteral("installedVersion"), version);
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

void Store::loadPermissions(const QString &appId)
{
    m_backend->getPermissions(appId);
}

QVariantMap Store::permissions(const QString &appId) const
{
    return m_permissions.value(appId);
}

void Store::withdrawPermission(const QString &appId, const QString &key)
{
    m_backend->withdrawPermission(appId, key);
}

void Store::restorePermission(const QString &appId, const QString &key)
{
    m_backend->restorePermission(appId, key);
}

void Store::resetPermissions(const QString &appId)
{
    m_backend->resetPermissions(appId);
}

QVariantMap Store::app(const QString &appId) const
{
    const auto it = m_catalogueIndex.constFind(appId);
    return it == m_catalogueIndex.cend() ? QVariantMap() : m_catalogue.at(it.value()).toMap();
}

QVariantMap Store::rowIds(bool gamepadOnly) const
{
    const QString id = QStringLiteral("id");
    const QString controller = QStringLiteral("controller");
    const QString source = QStringLiteral("source");
    QStringList all, featured, games, apps, installed;
    for (const QVariant &v : m_results) {
        const QVariantMap m = v.toMap();
        const QString c = m.value(controller).toString();
        if (gamepadOnly && c != QLatin1String("full") && c != QLatin1String("partial"))
            continue;
        if (!m.value(QStringLiteral("compatible"), true).toBool())
            continue; // needs a newer API level: not listed (its page still opens, RUY-156)
        const QString appId = m.value(id).toString();
        all.append(appId);
        if (m.value(source).toString() == QLatin1String("official"))
            featured.append(appId);
        if (c == QLatin1String("full"))
            games.append(appId);
        else
            apps.append(appId);
    }
    for (const QVariant &v : m_installed)
        installed.append(v.toMap().value(id).toString());
    return {{QStringLiteral("all"), all},
            {QStringLiteral("featured"), featured},
            {QStringLiteral("games"), games},
            {QStringLiteral("apps"), apps},
            {QStringLiteral("installed"), installed}};
}

void Store::indexCatalogue()
{
    // mergeDetails and patchFlags change records in place, never the order or the ids. An id listed
    // twice answers with its first record, as the scan this replaces did.
    m_catalogueIndex.clear();
    m_catalogueIndex.reserve(m_catalogue.size());
    for (int i = 0; i < m_catalogue.size(); ++i) {
        const QString id = m_catalogue.at(i).toMap().value(QStringLiteral("id")).toString();
        if (!m_catalogueIndex.contains(id))
            m_catalogueIndex.insert(id, i);
    }
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
    m_getOnly.clear();
    m_permissions.clear();
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

void Store::mockPauseJobs(bool paused)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->pauseJobs(paused);
}

void Store::mockEndJobsUnheard(const QString &status)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->endJobsUnheard(status);
}

void Store::mockRecordFinishedJob(const QString &appId, const QString &kind, const QString &status)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->recordFinishedJob(appId, kind, status);
}

void Store::mockListJobsFailing()
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->listJobsFailing();
}

void Store::mockInstalledDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->refreshDelayed(ms);
}

void Store::mockCatalogueDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->searchDelayed(ms);
}

int Store::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
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

void Store::mockArtDir(const QString &dir)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->setArtDir(dir);
}

void Store::mockAddApps(int count)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->addApps(count);
}

void Store::refreshInstalled()
{
    m_backend->refresh();
}

void Store::mockInstallOutside(const QString &appId, const QString &name, const QStringList &permissions)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->installOutside(appId, name, permissions);
}

void Store::mockSetApiLevel(int level)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->setApiLevel(level);
}

void Store::mockSearchReplyDelay(int ms)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->setSearchReplyMs(ms);
}

void Store::mockSetAppText(const QString &appId, const QString &name, const QString &summary, const QString &developer,
                           const QStringList &permissions)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->setAppText(appId, name, summary, developer, permissions);
}

void Store::mockCatalogChanged()
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->announceCatalogChanged();
}

void Store::mockPermissionsCallerAdmin(bool admin)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->setPermissionsCallerAdmin(admin);
}

void Store::mockPermissionsDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get()))
        mock->permissionsDelayed(ms);
}

int Store::mockPermissionReads() const
{
    auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get());
    return mock ? mock->permissionReads() : 0;
}

int Store::mockPendingPermissionReplies() const
{
    auto *mock = qobject_cast<MockStoreBackend *>(m_backend.get());
    return mock ? mock->pendingPermissionReplies() : 0;
}
