#include "MockStoreBackend.h"

#include <algorithm>

namespace {
const QString Broken = QStringLiteral("org.example.Broken");

AppInfo app(const char *id, const char *name, const char *summary, const char *developer, const char *source,
            const char *controller, const char *age, const QStringList &permissions, qulonglong megabytes)
{
    AppInfo a;
    a.id = QString::fromLatin1(id);
    a.name = QString::fromLatin1(name);
    a.summary = QString::fromLatin1(summary);
    a.description = a.summary + QStringLiteral(" This is mock catalogue text, long enough to wrap on a card.");
    a.developer = QString::fromLatin1(developer);
    a.source = QString::fromLatin1(source);
    a.controller = QString::fromLatin1(controller);
    a.ageRating = QString::fromLatin1(age);
    a.permissions = permissions;
    a.installedSize = megabytes * 1024 * 1024;
    return a;
}
} // namespace

MockStoreBackend::MockStoreBackend(QObject *parent)
    : StoreBackend(parent)
{
    if (qEnvironmentVariable("RUYA_MOCK_FAST") == QLatin1String("1"))
        m_stepMs = 10;
    m_timer.setInterval(m_stepMs);
    connect(&m_timer, &QTimer::timeout, this, [this] { step(); });
    initState();
}

void MockStoreBackend::initState()
{
    m_apps = {
        app("org.example.Racer", "Turbo Racer", "Arcade racing for up to four players.", "Example Games", "official",
            "full", "7+", {"audio", "gamepad"}, 820),
        app("org.example.Puzzle", "Block Puzzle", "A calm falling-blocks puzzler.", "Example Games", "official", "full",
            "all", {"audio", "gamepad"}, 95),
        app("org.example.Platformer", "Pixel Hopper", "Jump, dash and collect every star.", "Tiny Studio", "official",
            "full", "7+", {"audio", "gamepad"}, 310),
        app("org.example.Chess", "Open Chess", "Chess against the computer or a friend.", "Community", "community",
            "partial", "all", {"audio"}, 60),
        app("org.example.Retro", "Retro Station", "Play classic console games from your own files.", "Community",
            "community", "partial", "12+", {"audio", "gamepad", "home-files"}, 240),
        app("org.example.Player", "Open Player", "Movies and music from your network.", "Community", "community",
            "partial", "all", {"audio", "network", "host-files"}, 180),
        app("org.example.Browser", "Web Browser", "Browse the web with a mouse or keyboard.", "Community", "community",
            "none", "12+", {"audio", "network", "home-files"}, 410),
        app("org.example.Editor", "Text Editor", "A plain text editor.", "Community", "community", "none", "all",
            {"home-files"}, 45),
        app("org.example.Stream", "Game Streamer", "Stream games from your PC.", "Community", "community", "full",
            "12+", {"network", "audio", "gamepad", "all-devices"}, 150),
        app("org.example.Tools", "Dev Tools", "Experimental tools, may break.", "Some Developer", "developer", "none",
            "all", {"host-files", "session-bus", "network"}, 75),
        app("org.example.Beta", "Racer Beta", "Next version of Turbo Racer.", "Example Games", "developer", "full",
            "7+", {"audio", "gamepad", "network"}, 840),
        app("org.example.Broken", "Broken App", "Always fails to install; for tests.", "Example Games", "official",
            "partial", "all", {"audio"}, 20),
    };
    // Installed from the start; Open Chess has an update.
    for (const char *id : {"org.example.Puzzle", "org.example.Chess", "org.example.Editor"})
        m_apps[indexOf(QString::fromLatin1(id))].installed = true;
    m_apps[indexOf(QStringLiteral("org.example.Chess"))].updateAvailable = true;
}

void MockStoreBackend::reset()
{
    m_timer.stop();
    m_jobs.clear();
    m_dataDeleted.clear();
    initState();
    emit installedChanged();
}

int MockStoreBackend::indexOf(const QString &id) const
{
    for (int i = 0; i < m_apps.size(); ++i) {
        if (m_apps.at(i).id == id)
            return i;
    }
    return -1;
}

QList<AppInfo> MockStoreBackend::installedApps() const
{
    QList<AppInfo> out;
    for (const AppInfo &a : m_apps) {
        if (a.installed)
            out.append(a);
    }
    return out;
}

void MockStoreBackend::refresh()
{
    const QList<AppInfo> list = installedApps();
    QTimer::singleShot(0, this, [this, list] { emit installedListed(list); });
}

void MockStoreBackend::search(const QString &query)
{
    QList<AppInfo> out;
    for (const AppInfo &a : std::as_const(m_apps)) {
        if (query.isEmpty() || a.name.contains(query, Qt::CaseInsensitive)
            || a.summary.contains(query, Qt::CaseInsensitive) || a.id.contains(query, Qt::CaseInsensitive))
            out.append(a);
    }
    QTimer::singleShot(0, this, [this, query, out] { emit searchFinished(query, out); });
}

void MockStoreBackend::reject(const QString &id, const QString &status)
{
    QTimer::singleShot(0, this, [this, id, status] { emit jobFinished(id, status); });
}

void MockStoreBackend::startJob(const QString &id, Job::Kind kind)
{
    for (const Job &j : std::as_const(m_jobs)) {
        if (j.id == id) {
            reject(id, QStringLiteral("busy"));
            return;
        }
    }
    m_jobs.append({id, kind, 0});
    if (!m_timer.isActive())
        m_timer.start();
}

void MockStoreBackend::install(const QString &id)
{
    const int i = indexOf(id);
    if (i < 0)
        reject(id, QStringLiteral("unknown-app"));
    else if (m_apps.at(i).installed)
        reject(id, QStringLiteral("already-installed"));
    else
        startJob(id, Job::Install);
}

void MockStoreBackend::uninstall(const QString &id, bool deleteData)
{
    const int i = indexOf(id);
    if (i < 0) {
        reject(id, QStringLiteral("unknown-app"));
    } else if (!m_apps.at(i).installed) {
        reject(id, QStringLiteral("not-installed"));
    } else {
        if (deleteData)
            m_dataDeleted.insert(id);
        else
            m_dataDeleted.remove(id);
        startJob(id, Job::Uninstall);
    }
}

void MockStoreBackend::update(const QString &id)
{
    const int i = indexOf(id);
    if (i < 0)
        reject(id, QStringLiteral("unknown-app"));
    else if (!m_apps.at(i).installed)
        reject(id, QStringLiteral("not-installed"));
    else if (!m_apps.at(i).updateAvailable)
        reject(id, QStringLiteral("no-update"));
    else
        startJob(id, Job::Update);
}

void MockStoreBackend::step()
{
    if (m_jobs.isEmpty()) {
        m_timer.stop();
        return;
    }
    Job &job = m_jobs.first();
    job.percent = std::min(100, job.percent + (job.kind == Job::Uninstall ? 50 : 5));
    QString phase = QStringLiteral("remove");
    if (job.kind == Job::Update)
        phase = QStringLiteral("update");
    else if (job.kind == Job::Install)
        phase = job.percent < 50 ? QStringLiteral("download") : QStringLiteral("install");
    emit jobProgress(job.id, job.percent, phase);

    if (job.id == Broken && job.kind == Job::Install && job.percent >= 60) {
        const Job done = m_jobs.takeFirst();
        finish(done, QStringLiteral("failed"));
    } else if (job.percent >= 100) {
        const Job done = m_jobs.takeFirst();
        AppInfo &a = m_apps[indexOf(done.id)];
        a.installed = done.kind != Job::Uninstall;
        a.updateAvailable = false;
        emit installedChanged();
        finish(done, QStringLiteral("ok"));
    }
    if (m_jobs.isEmpty())
        m_timer.stop();
}

void MockStoreBackend::finish(const Job &job, const QString &status)
{
    emit jobFinished(job.id, status);
}
