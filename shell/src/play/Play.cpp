#include "Play.h"

#include "DBusPlayBackend.h"
#include "MockPlayBackend.h"

#include <algorithm>
#include <utility>

Play::Play(std::unique_ptr<PlayBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &PlayBackend::sourcesListed, this, [this](const QList<PlaySource> &sources) {
        QVariantList list;
        for (const PlaySource &s : sources)
            list.append(s.toVariant());
        setAvailable(true);
        if (list != m_sources) {
            m_sources = list;
            emit sourcesChanged();
        }
    });
    connect(m_backend.get(), &PlayBackend::sourcesChanged, this, [this] { m_backend->listSources(); });
    connect(m_backend.get(), &PlayBackend::inspected, this, [this](const QString &path, const PlayInfo &info) {
        emit inspected(path, info.toVariant());
    });
    connect(m_backend.get(), &PlayBackend::developerModeChanged, this, [this](bool on) {
        if (m_developerMode == on)
            return;
        m_developerMode = on;
        emit developerModeChanged();
    });
    connect(m_backend.get(), &PlayBackend::answered, this,
            [this](const QString &op, const QString &key, const QString &status) { emit answered(op, key, status); });
    connect(m_backend.get(), &PlayBackend::jobProgress, this, [this](const QString &key, int percent, const QString &phase) {
        m_lost.remove(key); // a job after the lost one: the lost one is history
        m_jobs.insert(key, QVariantMap{{QStringLiteral("percent"), percent}, {QStringLiteral("phase"), phase}});
        emit jobsChanged();
    });
    connect(m_backend.get(), &PlayBackend::jobFinished, this, [this](const QString &key, const QString &status) {
        m_lost.remove(key);
        if (m_jobs.remove(key))
            emit jobsChanged();
        emit jobFinished(key, status);
    });
    connect(m_backend.get(), &PlayBackend::serviceLost, this, [this](const QHash<QString, QString> &jobKeys) {
        setAvailable(false);
        // A job of the lost service never finishes; do not show it for ever. Pages waiting for its
        // result get "failed" so that they stop working.
        QStringList keys = m_jobs.keys();
        for (const QString &key : jobKeys) {
            if (!keys.contains(key))
                keys.append(key);
        }
        if (!m_jobs.isEmpty()) {
            m_jobs.clear();
            emit jobsChanged();
        }
        for (const QString &key : keys)
            m_lost.insert(key, jobKeys.key(key));
        for (const QString &key : keys)
            emit jobFinished(key, QStringLiteral("failed"));
    });
    connect(m_backend.get(), &PlayBackend::jobsListed, this, [this](const QList<StoreJob> &jobs) {
        setAvailable(true);
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
        // A job given up as failed may have a different result: found by its job id, not by its key.
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
    m_backend->listSources();
    m_backend->readDeveloperMode();
    m_backend->listJobs();
}

Play::~Play() = default;

Play *Play::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<PlayBackend> backend;
    // Like the Store: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockPlayBackend>();
    else
        backend = std::make_unique<DBusPlayBackend>();
    return new Play(std::move(backend));
}

void Play::setAvailable(bool available)
{
    if (m_available == available)
        return;
    m_available = available;
    emit availableChanged();
}

void Play::inspect(const QString &path)
{
    m_backend->inspect(path);
}

void Play::install(const QString &path, bool adminApproved)
{
    m_backend->install(path, adminApproved);
}

void Play::verify(const QString &appId)
{
    m_backend->verify(appId);
}

void Play::cancel(const QString &key)
{
    m_backend->cancel(key);
}

void Play::setDeveloperMode(bool on, bool adminApproved)
{
    m_backend->requestDeveloperMode(on, adminApproved);
}

void Play::refreshSources()
{
    m_backend->listSources();
}

void Play::mockReset()
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get())) {
        mock->reset();
        m_jobs.clear();
        m_lost.clear();
        emit jobsChanged();
        if (m_developerMode) {
            m_developerMode = false;
            emit developerModeChanged();
        }
        mock->listSources();
    }
}

void Play::mockSetDriveMounted(bool mounted)
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->setDriveMounted(mounted);
}

void Play::mockSetDeveloperMode(bool on)
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->setDeveloperMode(on);
}

void Play::mockSetInstalled(const QString &appId, uint build)
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->setInstalled(appId, build);
}

void Play::mockCorruptInstalled(const QString &appId)
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->corruptInstalled(appId);
}

void Play::mockPauseJobs(bool paused)
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->pauseJobs(paused);
}

void Play::mockPauseAtPercent(int percent)
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->pauseAtPercent(percent);
}

void Play::mockFailNext()
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->failNext();
}

void Play::mockServiceLost()
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->loseService();
}

void Play::mockServiceRegained()
{
    if (auto *mock = qobject_cast<MockPlayBackend *>(m_backend.get()))
        mock->regainService();
}

QString Play::mockPath(const QString &fixture) const
{
    return MockPlayBackend::pathOf(fixture);
}
