#include "MockPlayBackend.h"

#include <algorithm>

namespace {
const QString DriveId = QStringLiteral("vol-stick");
const QString DriveLabel = QStringLiteral("STICK");
const QString Root = QStringLiteral("/run/media/ruya/STICK/");
const qulonglong FreeBytes = 20ull * 1024 * 1024 * 1024;

PlayPermission perm(const char *key, const char *words, const char *risk)
{
    return {QString::fromLatin1(key), QString::fromLatin1(words), QString::fromLatin1(risk)};
}

PlayProblem problem(const char *code, const char *path, const char *message)
{
    return {QString::fromLatin1(code), QString::fromLatin1(path), QString::fromLatin1(message)};
}

// The outcomes whose cause Inspect can see: they are the record's verdict.
bool isVerdictStatus(const QString &s)
{
    static const QStringList seen = {QStringLiteral("invalid-package"), QStringLiteral("bad-signature"),
                                     QStringLiteral("different-developer"), QStringLiteral("needs-developer-mode"),
                                     QStringLiteral("revoked"), QStringLiteral("unsupported")};
    return seen.contains(s);
}

// Where in a job each cause shows (percent): staging < 20 <= verifying < 40 <= vetting-art < 55 <= committing < 70.
int failPercentOf(const QString &status)
{
    if (status == QLatin1String("needs-developer-mode") || status == QLatin1String("unsupported")
        || status == QLatin1String("disk-full"))
        return 10;
    if (status == QLatin1String("invalid-package"))
        return 15;
    if (status == QLatin1String("failed"))
        return 60;
    return 25; // bad-signature, different-developer, revoked
}
} // namespace

struct MockPlayBackend::Fixture
{
    QString name; // folder or file name on the drive
    QString kind;
    QString endStatus; // what an install ends with ("ok" or a JobFinished status)
    PlayInfo info;
};

const QList<MockPlayBackend::Fixture> &MockPlayBackend::fixtures()
{
    static const QList<Fixture> all = [] {
        QList<Fixture> out;
        auto add = [&out](const char *name, const char *kind, const char *end, PlayInfo i) {
            Fixture f;
            f.name = QString::fromLatin1(name);
            f.kind = QString::fromLatin1(kind);
            f.endStatus = QString::fromLatin1(end);
            i.path = Root + f.name;
            f.info = i;
            out.append(f);
        };
        auto base = [](const char *id, const char *name, const char *summary, const char *developer, uint build,
                       const char *tier, const char *controller, const char *age, qulonglong megabytes) {
            PlayInfo i;
            i.id = QString::fromLatin1(id);
            i.name = QString::fromLatin1(name);
            i.summary = QString::fromLatin1(summary);
            i.version = QStringLiteral("1.%1.0").arg(build);
            i.build = build;
            i.developer = QString::fromLatin1(developer);
            i.genres = {QStringLiteral("action")};
            i.players = QStringLiteral("1-2");
            i.controller = QString::fromLatin1(controller);
            i.ageLabel = QString::fromLatin1(age);
            i.size = megabytes * 1024 * 1024;
            i.tier = QString::fromLatin1(tier);
            if (i.tier != QLatin1String("unverified")) {
                i.signerKeyId = QStringLiteral("3f9a41c07be2d6058e21b4a9d0c7f312");
                i.signerName = i.developer;
                i.keyState = QStringLiteral("new");
            }
            i.art = {{QStringLiteral("icon"), Root + QStringLiteral(".vetted/") + i.id + QStringLiteral("/icon.webp")},
                     {QStringLiteral("card"), Root + QStringLiteral(".vetted/") + i.id + QStringLiteral("/card.webp")}};
            return i;
        };

        PlayInfo star = base("com.example.starhopper", "Star Hopper", "A Windows space shooter, run by Wine.",
                             "Example Games", 142, "developer", "full", "12+", 4800);
        star.genres = {QStringLiteral("shooter"), QStringLiteral("space")};
        star.permissions = {perm("input:controllers+keyboard-mouse", "Uses controllers, keyboard and mouse", "low"),
                            perm("network", "Uses the network", "medium"),
                            perm("removable_media:read", "Reads files on USB drives", "medium"),
                            perm("multiarch", "Runs 32-bit programs", "medium"),
                            perm("gamemode", "Asks the system to prioritise it", "low")};
        star.screenshots = {Root + QStringLiteral(".vetted/com.example.starhopper/shot1.webp")};
        add("starhopper", "folder", "ok", star);

        PlayInfo forest = base("com.example.pixelforest", "Pixel Forest", "A native platformer.", "Tiny Studio", 3,
                               "official", "full", "7+", 310);
        forest.keyState = QStringLiteral("same");
        forest.players = QStringLiteral("1");
        forest.permissions = {perm("input:controllers", "Uses controllers", "low")};
        add("pixelforest.play.zip", "zip", "ok", forest);

        PlayInfo home = base("com.example.homebrew", "Homebrew Quest", "Made by a stranger.", "Unknown", 1,
                             "unverified", "partial", "", 120);
        home.permissions = {perm("input:controllers+keyboard-mouse", "Uses controllers, keyboard and mouse", "low")};
        add("homebrew", "folder", "needs-developer-mode", home);

        PlayInfo bad = base("com.example.oldbad", "Old Bad Game", "Removed for safety.", "Shady Games", 7, "developer",
                            "none", "16+", 500);
        bad.revoked = true;
        bad.permissions = {perm("network", "Uses the network", "medium")};
        add("oldbad", "folder", "revoked", bad);

        PlayInfo broken = base("com.example.broken", "Broken Download", "The copy is damaged.", "Example Games", 2,
                               "developer", "full", "all", 900);
        broken.problems = {problem("package.hash_mismatch", "data/levels.pak", "hash differs from play.files"),
                           problem("package.missing_file", "data/music.pak", "listed in play.files, not in the package")};
        broken.permissions = {perm("input:controllers", "Uses controllers", "low")};
        add("broken", "folder", "invalid-package", broken);

        PlayInfo raw = base("com.example.rawaccess", "Raw Access", "Wants the whole machine.", "Example Games", 5,
                            "developer", "full", "all", 200);
        raw.permissions = {perm("input:all-devices", "Accesses all devices", "high"),
                           perm("devel", "Can inspect other programs", "high"),
                           perm("network", "Uses the network", "medium")};
        add("rawaccess.play.zip", "zip", "ok", raw);

        PlayInfo imp = base("com.example.impostor", "Pixel Forest 2", "Claims an id another key owns.", "Mallory Games",
                            4, "developer", "full", "all", 150);
        imp.keyState = QStringLiteral("different");
        imp.signerKeyId = QStringLiteral("c01d00d5badc0ffe7a3e91b2c4d5f608");
        imp.permissions = {perm("input:controllers", "Uses controllers", "low")};
        add("impostor", "folder", "different-developer", imp);

        PlayInfo tamp = base("com.example.tampered", "Tampered", "Changed after it was signed.", "Example Games", 9,
                             "developer", "full", "all", 150);
        tamp.permissions = {perm("input:controllers", "Uses controllers", "low")};
        add("tampered", "folder", "bad-signature", tamp);

        PlayInfo future = base("com.example.future", "From The Future", "Made for a newer console.", "Example Games",
                               1, "developer", "full", "all", 150);
        future.requirement = QStringLiteral("unsupported");
        future.problems = {problem("format.too_new", "/format", "play.json declares format 2")};
        add("future", "folder", "unsupported", future);

        PlayInfo huge = base("com.example.hugegame", "Huge Game", "Bigger than the free space.", "Example Games", 1,
                             "developer", "full", "16+", 60 * 1024);
        huge.permissions = {perm("input:controllers", "Uses controllers", "low")};
        add("hugegame.play.zip", "zip", "disk-full", huge);

        PlayInfo flaky = base("com.example.flaky", "Flaky Game", "The install breaks half way.", "Example Games", 1,
                              "developer", "full", "all", 150);
        flaky.permissions = {perm("input:controllers", "Uses controllers", "low")};
        add("flaky", "folder", "failed", flaky);
        return out;
    }();
    return all;
}

MockPlayBackend::MockPlayBackend(QObject *parent)
    : PlayBackend(parent)
{
    if (qEnvironmentVariable("RUYA_MOCK_FAST") == QLatin1String("1"))
        m_stepMs = 10;
    m_timer.setInterval(m_stepMs);
    connect(&m_timer, &QTimer::timeout, this, [this] { step(); });
    reset();
}

QString MockPlayBackend::pathOf(const QString &fixture)
{
    return Root + fixture;
}

void MockPlayBackend::reset()
{
    m_timer.stop();
    m_jobs.clear();
    m_finishedJobs.clear();
    m_installed = {{QStringLiteral("com.example.pixelforest"), 2u}};
    m_corrupt.clear();
    m_mounted = true;
    m_developerMode = false;
    m_paused = false;
    m_failNext = false;
    m_pauseAt = 0;
    jobBook().forgetAll();
}

const MockPlayBackend::Fixture *MockPlayBackend::fixtureAt(const QString &path) const
{
    if (!m_mounted)
        return nullptr;
    for (const Fixture &f : fixtures()) {
        if (f.info.path == path)
            return &f;
    }
    return nullptr;
}

QString MockPlayBackend::verdictOf(const Fixture &f) const
{
    if (f.endStatus == QLatin1String("needs-developer-mode") && m_developerMode)
        return QStringLiteral("ok");
    return isVerdictStatus(f.endStatus) ? f.endStatus : QStringLiteral("ok");
}

PlayInfo MockPlayBackend::infoOf(const Fixture &f) const
{
    PlayInfo i = f.info;
    i.verdict = verdictOf(f);
    i.installedBuild = m_installed.value(i.id, 0u);
    return i;
}

bool MockPlayBackend::failing(const QString &op, const QString &key)
{
    if (!m_failNext)
        return false;
    m_failNext = false;
    answerLater(op, key, QStringLiteral("failed"));
    return true;
}

void MockPlayBackend::answerLater(const QString &op, const QString &key, const QString &status)
{
    QTimer::singleShot(0, this, [this, op, key, status] { emit answered(op, key, status); });
}

void MockPlayBackend::listSources()
{
    QList<PlaySource> out;
    if (m_mounted) {
        for (const Fixture &f : fixtures())
            out.append({DriveId, DriveLabel, f.info.path, f.name, f.kind, f.kind == QLatin1String("zip") ? f.info.size : 0});
    }
    QTimer::singleShot(0, this, [this, out] { emit sourcesListed(out); });
}

void MockPlayBackend::setDriveMounted(bool mounted)
{
    if (m_mounted == mounted)
        return;
    m_mounted = mounted;
    emit sourcesChanged();
}

void MockPlayBackend::setDeveloperMode(bool on)
{
    m_developerMode = on;
}

void MockPlayBackend::corruptInstalled(const QString &appId)
{
    m_corrupt.insert(appId);
}

void MockPlayBackend::inspect(const QString &path)
{
    if (failing(QStringLiteral("inspect"), path))
        return;
    if (!path.startsWith(QLatin1Char('/'))) {
        answerLater(QStringLiteral("inspect"), path, QStringLiteral("invalid"));
        return;
    }
    const Fixture *f = fixtureAt(path);
    if (!f) {
        answerLater(QStringLiteral("inspect"), path, QStringLiteral("unknown-source"));
        return;
    }
    const PlayInfo info = infoOf(*f);
    QTimer::singleShot(0, this, [this, path, info] {
        emit answered(QStringLiteral("inspect"), path, QStringLiteral("ok"));
        emit inspected(path, info);
    });
}

void MockPlayBackend::startJob(const QString &op, const QString &key, const QString &kind, const QString &app,
                               const QString &path, int failAt, const QString &failStatus)
{
    for (const Job &j : std::as_const(m_jobs)) {
        if (j.key == key) {
            answerLater(op, key, QStringLiteral("busy"));
            return;
        }
    }
    Job job;
    job.key = key;
    job.kind = kind;
    job.jobId = QStringLiteral("play-mock-%1").arg(++m_jobCounter);
    job.app = app;
    job.path = path;
    job.failAt = failAt;
    job.failStatus = failStatus;
    m_jobs.append(job);
    jobBook().track(job.jobId, key); // as the D-Bus client does once the call is answered
    answerLater(op, key, QStringLiteral("ok"));
    if (!m_paused && !m_timer.isActive())
        m_timer.start();
}

void MockPlayBackend::install(const QString &path, bool adminApproved)
{
    const QString op = QStringLiteral("install");
    if (failing(op, path))
        return;
    if (!path.startsWith(QLatin1Char('/'))) {
        answerLater(op, path, QStringLiteral("invalid"));
        return;
    }
    const Fixture *f = fixtureAt(path);
    if (!f) {
        answerLater(op, path, QStringLiteral("unknown-source"));
        return;
    }
    if (!adminApproved) {
        answerLater(op, path, QStringLiteral("forbidden"));
        return;
    }
    // With developer mode on, the unverified one installs.
    const QString end = f->endStatus == QLatin1String("needs-developer-mode") && m_developerMode
        ? QStringLiteral("ok") : f->endStatus;
    startJob(op, path, QStringLiteral("install"), QStringLiteral("play.") + f->info.id, path,
             end == QLatin1String("ok") ? 101 : failPercentOf(end), end == QLatin1String("ok") ? QString() : end);
}

void MockPlayBackend::verify(const QString &appId)
{
    const QString op = QStringLiteral("verify");
    if (failing(op, appId))
        return;
    if (appId.isEmpty()) {
        answerLater(op, appId, QStringLiteral("invalid"));
        return;
    }
    const QString id = appId.startsWith(QLatin1String("play.")) ? appId.mid(5) : appId;
    if (!m_installed.contains(id)) {
        answerLater(op, appId, QStringLiteral("unknown-app"));
        return;
    }
    const bool bad = m_corrupt.contains(appId);
    // A verify only ever reports "verifying": the whole 0-100 range is one phase.
    startJob(op, appId, QStringLiteral("verify"), appId, QString(), bad ? 60 : 101,
             bad ? QStringLiteral("invalid-package") : QString());
}

void MockPlayBackend::cancel(const QString &key)
{
    const QString op = QStringLiteral("cancel");
    if (failing(op, key))
        return;
    for (int i = 0; i < m_jobs.size(); ++i) {
        const Job &j = m_jobs.at(i);
        if (j.jobId != key && j.key != key)
            continue;
        if (j.kind == QLatin1String("install") && j.percent >= 55) {
            answerLater(op, key, QStringLiteral("too-late"));
            return;
        }
        const Job gone = m_jobs.takeAt(i);
        answerLater(op, key, QStringLiteral("ok"));
        finish(gone, QStringLiteral("cancelled"));
        if (m_jobs.isEmpty())
            m_timer.stop();
        return;
    }
    answerLater(op, key, QStringLiteral("unknown-job"));
}

QString MockPlayBackend::phaseAt(int percent)
{
    if (percent < 20)
        return QStringLiteral("staging");
    if (percent < 40)
        return QStringLiteral("verifying");
    if (percent < 55)
        return QStringLiteral("vetting-art");
    if (percent < 70)
        return QStringLiteral("committing");
    return QStringLiteral("installing");
}

void MockPlayBackend::step()
{
    if (m_jobs.isEmpty()) {
        m_timer.stop();
        return;
    }
    Job &job = m_jobs.first();
    job.percent = std::min(100, job.percent + 5);
    const QString phase = job.kind == QLatin1String("verify") ? QStringLiteral("verifying") : phaseAt(job.percent);
    jobBook().onProgress(job.jobId, uint(job.percent), phase);
    if (m_pauseAt > 0 && job.percent >= m_pauseAt && job.percent < job.failAt && job.percent < 100) {
        m_pauseAt = 0;
        m_paused = true;
        m_timer.stop();
        return;
    }

    if (job.percent >= job.failAt) {
        const Job done = m_jobs.takeFirst();
        finish(done, done.failStatus);
    } else if (job.percent >= 100) {
        const Job done = m_jobs.takeFirst();
        if (done.kind == QLatin1String("install")) {
            const Fixture *f = fixtureAt(done.path);
            if (f)
                m_installed.insert(f->info.id, f->info.build);
        }
        finish(done, QStringLiteral("ok"));
    }
    if (m_jobs.isEmpty())
        m_timer.stop();
}

void MockPlayBackend::finish(const Job &job, const QString &status, const QString &reason)
{
    m_finishedJobs.append({job.jobId, job.key, job.kind, QStringLiteral("finished"), status, reason,
                           status == QLatin1String("ok") ? 100u : uint(job.percent), QString()});
    while (m_finishedJobs.size() > 20)
        m_finishedJobs.removeFirst();
    jobBook().onFinished(job.jobId, status);
}

QList<StoreJob> MockPlayBackend::jobTable() const
{
    QList<StoreJob> out = m_finishedJobs;
    for (int i = 0; i < m_jobs.size(); ++i) {
        const Job &j = m_jobs.at(i);
        const bool running = i == 0 && !m_paused;
        const bool started = j.percent > 0;
        out.append({j.jobId, j.key, j.kind, running || started ? QStringLiteral("running") : QStringLiteral("queued"),
                    QString(), QString(), uint(j.percent),
                    started ? (j.kind == QLatin1String("verify") ? QStringLiteral("verifying") : phaseAt(j.percent))
                            : QString()});
    }
    return out;
}

void MockPlayBackend::listJobs()
{
    const quint64 request = jobBook().listSent();
    const QList<StoreJob> table = jobTable();
    QTimer::singleShot(0, this, [this, request, table] { jobBook().listAnswered(request, table); });
}

void MockPlayBackend::pauseJobs(bool paused)
{
    m_paused = paused;
    if (paused)
        m_timer.stop();
    else if (!m_jobs.isEmpty())
        m_timer.start();
}

void MockPlayBackend::loseService()
{
    for (const Job &j : std::as_const(m_jobs)) {
        // The service cannot resume: the job ends as failed, interrupted.
        m_finishedJobs.append({j.jobId, j.key, j.kind, QStringLiteral("finished"), QStringLiteral("failed"),
                               QStringLiteral("interrupted"), uint(j.percent), QString()});
    }
    m_timer.stop();
    m_jobs.clear();
    emit serviceLost(jobBook().lose());
}

void MockPlayBackend::regainService()
{
    listSources();
    listJobs();
}
