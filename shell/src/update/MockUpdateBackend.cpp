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
    m_paused = false;
    m_rollbackCount = 0;
    publish();
}

void MockUpdateBackend::setRollbackAvailable(bool available)
{
    m_status.rollbackAvailable = available;
    publish();
}

void MockUpdateBackend::resume()
{
    m_pauseAt = -1;
    m_paused = false;
}

void MockUpdateBackend::refresh()
{
    publish();
}

bool MockUpdateBackend::isRunning() const
{
    return m_status.state == CheckingState || m_status.state == DownloadingState;
}

// Asynchronous like the real service, so QML behaves the same with either backend.
void MockUpdateBackend::publish()
{
    const UpdateStatus copy = m_status;
    QTimer::singleShot(0, this, [this, copy] { emit statusChanged(copy); });
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

void MockUpdateBackend::download()
{
    if (isRunning())
        return finish(QStringLiteral("download"), Busy);
    if (m_status.available.isEmpty())
        return finish(QStringLiteral("download"), Unavailable);
    m_status.state = DownloadingState;
    m_status.progress = 0;
    m_status.error.clear();
    m_paused = false;
    m_timer.start();
    publish();
    finish(QStringLiteral("download"), Ok);
}

void MockUpdateBackend::rollback()
{
    if (isRunning())
        return finish(QStringLiteral("rollback"), Busy);
    if (!m_status.rollbackAvailable)
        return finish(QStringLiteral("rollback"), Unavailable);
    ++m_rollbackCount;
    m_status.rollbackAvailable = false;
    m_status.state = StagedState;
    m_status.staged = QStringLiteral("0.0.17");
    m_status.available.clear();
    publish();
    finish(QStringLiteral("rollback"), Ok);
}

void MockUpdateBackend::setChannel(const QString &channel)
{
    if (channel != QLatin1String("stable") && channel != QLatin1String("beta"))
        return finish(QStringLiteral("setChannel"), QStringLiteral("invalid"));
    if (isRunning())
        return finish(QStringLiteral("setChannel"), Busy);
    m_status.channel = channel;
    m_status.available.clear();
    if (m_status.state == UpToDateState || m_status.state == FailedState)
        m_status.state = IdleState;
    publish();
    finish(QStringLiteral("setChannel"), Ok);
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
        if (m_paused)
            return;
        m_status.progress = qMin(100, m_status.progress + 10);
        if (m_status.progress == m_pauseAt)
            m_paused = true;
        if (m_status.progress >= 100) {
            m_timer.stop();
            m_status.state = StagedState;
            m_status.staged = m_status.available;
            m_status.available.clear();
            m_status.rollbackAvailable = true;
            m_updateExists = false;
        }
        publish();
    } else {
        m_timer.stop();
    }
}
