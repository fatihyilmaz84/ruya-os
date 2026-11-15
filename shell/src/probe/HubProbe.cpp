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
    for (QMetaObject::Connection *c : {&m_ownCommit, &m_ownSwap, &m_resumeCommit, &m_resumeSwap}) {
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
    const QMetaMethod swap = signalOf(m_window, "frameSwapped()");
    const QMetaObject *meta = metaObject();
    auto slot = [meta](const char *sig) { return meta->method(meta->indexOfSlot(sig)); };
    const bool counting = m_countFrames && commit.isValid() && swap.isValid();
    if (counting) {
        m_commitSeen.store(false);
        m_ownCommit = connect(m_surface, commit, this, slot("onOwnCommit()"), Qt::DirectConnection);
        m_ownSwap = connect(m_window, swap, this, slot("onOwnSwap()"), Qt::DirectConnection);
    }
    if (m_pending) {
        if (commit.isValid())
            m_resumeCommit = connect(m_surface, commit, this, slot("onResumeCommit()"));
        if (swap.isValid())
            m_resumeSwap = connect(m_window, swap, this, slot("onResumeSwap()"), Qt::QueuedConnection);
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

// A presented frame after a commit shows the game's buffer; one without is the shell's own.
void HubProbe::onOwnSwap()
{
    if (!m_commitSeen.exchange(false))
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
    m_committed = false;
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

void HubProbe::onResumeCommit()
{
    if (m_armed)
        m_committed = true;
}

void HubProbe::onResumeSwap()
{
    if (m_pending && m_armed && m_committed)
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
