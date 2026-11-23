#include "MockUpdateBackend.h"

#include <QDateTime>

namespace {
const QString IdleState = QStringLiteral("idle");
const QString CheckingState = QStringLiteral("checking");
const QString DownloadingState = QStringLiteral("downloading");
const QString StagedState = QStringLiteral("staged");
const QString UpToDateState = QStringLiteral("up-to-date");
const QString FailedState = QStringLiteral("failed");
const QString Ok = QStringLiteral("ok");
const QString Busy = QStringLiteral("busy");
const QString Unavailable = QStringLiteral("unavailable");
const QString Forbidden = QStringLiteral("forbidden");
const QString WrongState = QStringLiteral("wrong-state");
const QString Unsupported = QStringLiteral("unsupported");
// The image job (Update1's Job record).
const QString JobRunning = QStringLiteral("running");
const QString JobPaused = QStringLiteral("paused");
const QString JobFinished = QStringLiteral("finished");
const QString PhaseDownload = QStringLiteral("download");
const QString PhaseInstall = QStringLiteral("install");
// The service's mapping: bytes fill 0..90 %, the import and deploy 90..99, staged is 100.
constexpr int DownloadEnd = 90;
constexpr int InstallStep = 95;
// What the Dell's 0.0.105 -> 0.0.106 run had to fetch, at a plausible rate.
constexpr qulonglong MockBytesTotal = 2381035309ULL;
constexpr qulonglong MockRateBps = 25000000ULL;
} // namespace

MockUpdateBackend::MockUpdateBackend(QObject *parent)
    : UpdateBackend(parent)
{
    if (qEnvironmentVariable("RUYA_MOCK_FAST") == QLatin1String("1"))
        m_stepMs = 10;
    m_timer.setInterval(m_stepMs);
    connect(&m_timer, &QTimer::timeout, this, [this] { step(); });
    reset();
}

void MockUpdateBackend::reset()
{
    m_timer.stop();
    m_status = UpdateStatus();
    m_status.current = QStringLiteral("0.0.18");
    m_status.rollbackAvailable = true;
    m_checkTicks = 0;
    m_updateExists = true;
    m_failNext = false;
    m_pauseAt = -1;
    m_held = false;
    m_rollbackCount = 0;
    m_activityCount = 0;
    m_lastAppRunning = false;
    m_callerIsAdmin = true;
    m_jobId.clear();
    m_jobVersion.clear();
    m_jobState.clear();
    m_jobStatus.clear();
    m_jobPhase = PhaseDownload;
    m_jobStarted = 0;
    m_jobFinished = 0;
    publish();
    publishJob();
}

void MockUpdateBackend::setRollbackAvailable(bool available)
{
    m_status.rollbackAvailable = available;
    publish();
}

void MockUpdateBackend::resume()
{
    m_pauseAt = -1;
    m_held = false;
}

void MockUpdateBackend::refresh()
{
    publish();
    publishJob();
}

bool MockUpdateBackend::isRunning() const
{
    return m_status.state == CheckingState || m_status.state == DownloadingState;
}

// Asynchronous like the real service, so QML behaves the same with either backend.
void MockUpdateBackend::publish()
{
    publishAfter(0);
}

void MockUpdateBackend::publishAfter(int ms)
{
    const quint64 request = beginStatusRequest();
    const UpdateStatus copy = m_status;
    ++m_pending;
    QTimer::singleShot(ms, this, [this, request, copy] {
        --m_pending;
        deliverStatus(request, copy);
    });
}

QVariantMap MockUpdateBackend::jobRecord() const
{
    if (m_jobState.isEmpty())
        return {};
    const bool running = m_jobState == JobRunning;
    const bool fetching = running && m_jobPhase == PhaseDownload;
    const int percent = m_status.progress;
    const qulonglong done = MockBytesTotal * qulonglong(qMin(percent, DownloadEnd)) / qulonglong(DownloadEnd);
    const qulonglong left = MockBytesTotal - done;
    return {
        {QStringLiteral("id"), m_jobId},
        {QStringLiteral("source"), QStringLiteral("update")},
        {QStringLiteral("kind"), QStringLiteral("os")},
        {QStringLiteral("app"), QString()},
        {QStringLiteral("title"), QStringLiteral("RuyaOS %1").arg(m_jobVersion)},
        {QStringLiteral("state"), m_jobState},
        {QStringLiteral("status"), m_jobStatus},
        {QStringLiteral("reason"), QString()},
        {QStringLiteral("phase"), m_jobPhase},
        {QStringLiteral("percent"), uint(percent)},
        {QStringLiteral("bytes_done"), done},
        {QStringLiteral("bytes_total"), MockBytesTotal},
        {QStringLiteral("rate_bps"), fetching ? MockRateBps : qulonglong(0)},
        {QStringLiteral("eta_s"), fetching ? uint((left + MockRateBps - 1) / MockRateBps) : uint(0)},
        {QStringLiteral("position"), uint(0)},
        {QStringLiteral("resumable"), m_jobState != JobFinished && m_jobPhase == PhaseDownload},
        {QStringLiteral("started"), m_jobStarted},
        {QStringLiteral("finished"), m_jobFinished},
    };
}

void MockUpdateBackend::publishJob()
{
    const quint64 request = beginJobRequest();
    const QVariantMap copy = jobRecord();
    QTimer::singleShot(0, this, [this, request, copy] { deliverJob(request, copy); });
}

void MockUpdateBackend::finish(const QString &method, const QString &status)
{
    QTimer::singleShot(0, this, [this, method, status] { emit requestFinished(method, status); });
}

void MockUpdateBackend::check()
{
    if (isRunning())
        return finish(QStringLiteral("check"), Busy);
    if (m_failNext) {
        m_failNext = false;
        m_status.state = FailedState;
        m_status.error = QStringLiteral("Could not reach the update server.");
        publish();
        return finish(QStringLiteral("check"), QStringLiteral("failed"));
    }
    m_status.state = CheckingState;
    m_status.error.clear();
    m_checkTicks = 0;
    m_timer.start();
    publish();
    finish(QStringLiteral("check"), Ok);
}

// A new job, or the paused one again (its percent stays).
void MockUpdateBackend::startDownload()
{
    if (m_jobState != JobPaused) {
        const qint64 now = QDateTime::currentSecsSinceEpoch();
        // As the service: "os-<seconds>", with a suffix when the last job began in that second.
        const QString base = QStringLiteral("os-%1").arg(now);
        QString id = base;
        for (int n = 2; id == m_jobId; ++n)
            id = QStringLiteral("%1-%2").arg(base).arg(n);
        m_jobId = id;
        m_jobVersion = m_status.available;
        m_jobStarted = now;
        m_jobFinished = 0;
        m_status.progress = 0;
    }
    m_jobState = JobRunning;
    m_jobStatus.clear();
    m_jobPhase = PhaseDownload;
    m_status.state = DownloadingState;
    m_status.error.clear();
    m_held = false;
    m_timer.start();
    publish();
    publishJob();
}

void MockUpdateBackend::endJob(const QString &status)
{
    m_jobState = JobFinished;
    m_jobStatus = status;
    m_jobFinished = QDateTime::currentSecsSinceEpoch();
}

void MockUpdateBackend::cancelPausedJob()
{
    if (m_jobState != JobPaused)
        return;
    endJob(QStringLiteral("cancelled"));
    publishJob();
}

void MockUpdateBackend::download()
{
    if (isRunning())
        return finish(QStringLiteral("download"), Busy);
    if (m_jobState != JobPaused && m_status.available.isEmpty())
        return finish(QStringLiteral("download"), Unavailable);
    startDownload();
    finish(QStringLiteral("download"), Ok);
}

void MockUpdateBackend::pauseDownload()
{
    if (m_jobState != JobRunning)
        return finish(QStringLiteral("pauseDownload"), WrongState);
    if (m_jobPhase != PhaseDownload)
        return finish(QStringLiteral("pauseDownload"), Unsupported);
    m_timer.stop();
    m_jobState = JobPaused;
    m_status.state = m_status.staged.isEmpty() ? IdleState : StagedState;
    publish();
    publishJob();
    finish(QStringLiteral("pauseDownload"), Ok);
}

void MockUpdateBackend::resumeDownload()
{
    if (m_jobState != JobPaused)
        return finish(QStringLiteral("resumeDownload"), WrongState);
    if (isRunning())
        return finish(QStringLiteral("resumeDownload"), Busy);
    startDownload();
    finish(QStringLiteral("resumeDownload"), Ok);
}

void MockUpdateBackend::cancelDownload()
{
    if (m_jobState == JobPaused) {
        cancelPausedJob();
        return finish(QStringLiteral("cancelDownload"), Ok);
    }
    if (m_jobState != JobRunning)
        return finish(QStringLiteral("cancelDownload"), WrongState);
    if (m_jobPhase != PhaseDownload)
        return finish(QStringLiteral("cancelDownload"), Unsupported);
    m_timer.stop();
    endJob(QStringLiteral("cancelled"));
    m_status.state = m_status.staged.isEmpty() ? IdleState : StagedState;
    publish();
    publishJob();
    finish(QStringLiteral("cancelDownload"), Ok);
}

void MockUpdateBackend::rollback()
{
    if (!m_callerIsAdmin)
        return finish(QStringLiteral("rollback"), Forbidden);
    if (isRunning())
        return finish(QStringLiteral("rollback"), Busy);
    if (!m_status.rollbackAvailable)
        return finish(QStringLiteral("rollback"), Unavailable);
    ++m_rollbackCount;
    m_status.rollbackAvailable = false;
    m_status.state = StagedState;
    m_status.staged = QStringLiteral("0.0.17");
    m_status.available.clear();
    cancelPausedJob();
    publish();
    finish(QStringLiteral("rollback"), Ok);
}

void MockUpdateBackend::setChannel(const QString &channel)
{
    if (!m_callerIsAdmin)
        return finish(QStringLiteral("setChannel"), Forbidden);
    if (channel != QLatin1String("stable") && channel != QLatin1String("beta"))
        return finish(QStringLiteral("setChannel"), QStringLiteral("invalid"));
    if (isRunning())
        return finish(QStringLiteral("setChannel"), Busy);
    m_status.channel = channel;
    m_status.available.clear();
    if (m_status.state == UpToDateState || m_status.state == FailedState)
        m_status.state = IdleState;
    cancelPausedJob();
    publish();
    finish(QStringLiteral("setChannel"), Ok);
}

void MockUpdateBackend::setAutoRestart(bool enabled)
{
    if (!m_callerIsAdmin)
        return finish(QStringLiteral("setAutoRestart"), Forbidden);
    m_status.autoRestart = enabled;
    publish();
    finish(QStringLiteral("setAutoRestart"), Ok);
}

void MockUpdateBackend::reportActivity(bool appRunning)
{
    ++m_activityCount;
    m_lastAppRunning = appRunning;
    if (m_status.restartAt != 0) {
        m_status.restartAt = 0;
        publish();
    }
}

void MockUpdateBackend::announceRestart(qint64 restartAt)
{
    m_status.restartAt = restartAt;
    publish();
}

void MockUpdateBackend::step()
{
    if (m_status.state == CheckingState) {
        if (++m_checkTicks < 3)
            return;
        m_timer.stop();
        m_status.lastCheck = QDateTime::currentSecsSinceEpoch();
        if (!m_status.staged.isEmpty()) {
            m_status.state = StagedState;       // already waiting for a restart
        } else if (m_updateExists) {
            m_status.state = IdleState;
            m_status.available = QStringLiteral("0.0.19");
        } else {
            m_status.state = UpToDateState;
            m_status.available.clear();
        }
        publish();
    } else if (m_status.state == DownloadingState) {
        if (m_held)
            return;
        if (m_status.progress < DownloadEnd) {
            m_status.progress = qMin(DownloadEnd, m_status.progress + 10);
        } else if (m_status.progress < InstallStep) {
            m_status.progress = InstallStep;
            m_jobPhase = PhaseInstall;
        } else {
            m_status.progress = 100;
        }
        if (m_status.progress == m_pauseAt)
            m_held = true;
        if (m_status.progress >= 100) {
            m_timer.stop();
            endJob(Ok);
            m_status.state = StagedState;
            m_status.staged = m_status.available.isEmpty() ? m_jobVersion : m_status.available;
            m_status.available.clear();
            m_status.rollbackAvailable = true;
            m_updateExists = false;
        }
        publish();
        publishJob();
    } else {
        m_timer.stop();
    }
}
