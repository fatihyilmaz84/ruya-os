#include "HubProbe.h"

#include <QMetaMethod>

namespace {
QMetaMethod signalOf(const QObject *object, const char *signature)
{
    if (!object)
        return {};
    const QMetaObject *meta = object->metaObject();
    const int index = meta->indexOfSignal(signature);
    return index >= 0 ? meta->method(index) : QMetaMethod();
}
} // namespace

HubProbe::HubProbe(QObject *parent)
    : QObject(parent)
{
    m_clock.start();
    m_timeout.setSingleShot(true);
    m_timeout.setInterval(2000);
    connect(&m_timeout, &QTimer::timeout, this, &HubProbe::onTimeout);
    m_logTimer.setInterval(1000);
    connect(&m_logTimer, &QTimer::timeout, this, &HubProbe::logOwn);
    m_countFrames = qEnvironmentVariableIsSet("RUYA_PERF_LOG");
}

HubProbe::~HubProbe()
{
    disconnectAll();
}

void HubProbe::setWindow(QObject *window)
{
    if (window == m_window)
        return;
    QObject::disconnect(m_windowGone);
    m_window = window;
    if (window)
        m_windowGone = connect(window, &QObject::destroyed, this, [this] { reconnect(); });
    reconnect();
    emit windowChanged();
}

void HubProbe::setSurface(QObject *surface)
{
    if (surface == m_surface)
        return;
    QObject::disconnect(m_surfaceGone);
    m_surface = surface;
    if (surface)
        m_surfaceGone = connect(surface, &QObject::destroyed, this, [this] { reconnect(); });
    reconnect();
    emit surfaceChanged();
}

void HubProbe::setCountFrames(bool on)
{
    if (on == m_countFrames)
        return;
    m_countFrames = on;
    reconnect();
}

void HubProbe::setTimeoutMs(int ms)
{
    if (ms <= 0 || ms == m_timeout.interval())
        return;
    m_timeout.setInterval(ms);
    emit timeoutMsChanged();
}

void HubProbe::disconnectAll()
{
    for (QMetaObject::Connection *c : {&m_ownCommit, &m_ownSync, &m_ownSwap, &m_resumeCommit, &m_resumeSync, &m_resumeSwap}) {
        QObject::disconnect(*c);
        *c = QMetaObject::Connection();
    }
}

// The connections that should exist now: the own-frame count while counting, the Resume's while one
// is measured. Nothing else is connected, so an idle shell posts no call per frame.
void HubProbe::reconnect()
{
    disconnectAll();
    const QMetaMethod commit = signalOf(m_surface, "redraw()");
    const QMetaMethod sync = signalOf(m_window, "afterSynchronizing()");
    const QMetaMethod swap = signalOf(m_window, "frameSwapped()");
    const QMetaObject *meta = metaObject();
    auto slot = [meta](const char *sig) { return meta->method(meta->indexOfSlot(sig)); };
    const bool framed = commit.isValid() && sync.isValid() && swap.isValid();
    const bool counting = m_countFrames && framed;
    if (counting) {
        m_commitSeen.store(false);
        m_frameHadCommit.store(false);
        m_ownCommit = connect(m_surface, commit, this, slot("onOwnCommit()"), Qt::DirectConnection);
        m_ownSync = connect(m_window, sync, this, slot("onOwnSync()"), Qt::DirectConnection);
        m_ownSwap = connect(m_window, swap, this, slot("onOwnSwap()"), Qt::DirectConnection);
    }
    if (m_pending) {
        if (framed) {
            m_resumeCommitSeen.store(false);
            m_resumeFrameHadCommit.store(false);
            m_resumeCommit = connect(m_surface, commit, this, slot("onResumeCommit()"), Qt::DirectConnection);
            m_resumeSync = connect(m_window, sync, this, slot("onResumeSync()"), Qt::DirectConnection);
            m_resumeSwap = connect(m_window, swap, this, slot("onResumeSwap()"), Qt::DirectConnection);
        }
    }
    if (counting != m_counting) {
        m_counting = counting;
        if (counting) {
            m_ownLogged = m_own.load();
            m_logTimer.start();
        } else {
            m_logTimer.stop();
        }
        emit countingChanged();
    }
}

void HubProbe::onOwnCommit()
{
    m_commitSeen.store(true);
}

// The frame takes the game's buffer at its sync: it shows a new game frame when a commit came since the
// sync before. One that took none is the shell's own (counted at its swap).
void HubProbe::onOwnSync()
{
    m_frameHadCommit.store(m_commitSeen.exchange(false));
}

void HubProbe::onOwnSwap()
{
    if (!m_frameHadCommit.exchange(false))
        m_own.fetch_add(1);
}

void HubProbe::logOwn()
{
    const int total = m_own.load();
    qInfo("ruya-shell: perf-own frames=%d window=1s", total - m_ownLogged);
    m_ownLogged = total;
    emit framesChanged();
}

void HubProbe::begin(const QString &instance)
{
    m_pending = true;
    m_instance = instance;
    m_reply = -1;
    m_status.clear();
    m_armed = false;
    m_resumeCommitSeen.store(false);
    m_resumeFrameHadCommit.store(false);
    m_clock.restart();
    m_timeout.start();
    reconnect();
    emit stateChanged();
}

void HubProbe::thawAnswered(const QString &instance, const QString &status)
{
    if (!m_pending || instance != m_instance || m_reply >= 0)
        return;
    m_reply = now();
    m_status = status;
    if (status != QLatin1String("ok")) {
        finish(QString());
        return;
    }
    m_armed = true;
    m_timeout.start();      // the frame has timeoutMs from the reply
}

void HubProbe::cancel()
{
    if (!m_pending)
        return;
    m_pending = false;
    m_armed = false;
    m_timeout.stop();
    reconnect();
    emit stateChanged();
}

// Only commits after the Thaw reply count (m_armed is set on the GUI thread, where the surface signals).
void HubProbe::onResumeCommit()
{
    if (m_armed)
        m_resumeCommitSeen.store(true);
}

void HubProbe::onResumeSync()
{
    m_resumeFrameHadCommit.store(m_resumeCommitSeen.exchange(false));
}

// The first frame that took such a commit at its sync is the game's next presented frame; the render
// thread hands it to the GUI thread.
void HubProbe::onResumeSwap()
{
    if (m_resumeFrameHadCommit.exchange(false))
        QMetaObject::invokeMethod(this, "onResumeFrame", Qt::QueuedConnection);
}

void HubProbe::onResumeFrame()
{
    if (m_pending && m_armed)
        finish(QString::number(now()));
}

void HubProbe::onTimeout()
{
    if (!m_pending)
        return;
    if (m_reply < 0)
        m_reply = -2;       // no reply at all
    finish(m_armed ? QStringLiteral("timeout") : QString());
}

void HubProbe::finish(const QString &firstFrame)
{
    m_timeout.stop();
    QString line = QStringLiteral("hub-resume thawReply=%1")
                       .arg(m_reply == -2 ? QStringLiteral("timeout") : QString::number(m_reply));
    if (!firstFrame.isEmpty())
        line += QStringLiteral(" firstFrame=%1").arg(firstFrame);
    line += QStringLiteral(" status=%1").arg(m_status.isEmpty() ? QStringLiteral("none") : m_status);
    m_lastLine = line;
    qInfo("ruya-shell: %s", qPrintable(m_lastLine));
    ++m_lineCount;
    m_pending = false;
    m_armed = false;
    reconnect();
    emit stateChanged();
}
