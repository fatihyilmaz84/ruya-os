#include "PageProbe.h"

PageProbe::PageProbe(QObject *parent)
    : QObject(parent)
{
    m_clock.start();
}

void PageProbe::setWindow(QQuickWindow *window)
{
    if (m_window == window)
        return;
    disconnectSwap();
    m_window = window;
    if (!m_key.isEmpty())
        connectSwap();
    emit windowChanged();
}

// frameSwapped comes from the render thread in the threaded render loop: queued, so the probe only
// ever runs on the GUI thread. It is connected only while a page open is being measured, so an idle
// shell posts no call per frame.
void PageProbe::connectSwap()
{
    if (m_window && !m_swapConnection)
        m_swapConnection = connect(m_window, &QQuickWindow::frameSwapped, this, &PageProbe::onFrameSwapped,
                                   Qt::QueuedConnection);
}

void PageProbe::disconnectSwap()
{
    if (m_swapConnection) {
        disconnect(m_swapConnection);
        m_swapConnection = QMetaObject::Connection();
    }
}

void PageProbe::begin(const QString &key)
{
    m_key = key;
    m_create = -1;
    m_firstSwap = -1;
    m_afterAnim = -1;
    m_frames = 0;
    m_maxFrame = 0;
    m_clock.restart();
    m_lastFrame = 0;
    connectSwap();
    emit stateChanged();
}

void PageProbe::created(const QString &key)
{
    if (key != m_key || m_create >= 0)
        return;
    m_create = now();
    emit stateChanged();
}

void PageProbe::settled(const QString &key)
{
    if (key != m_key || m_create < 0 || m_afterAnim >= 0)
        return;
    m_afterAnim = now();
    finishIfDone();
}

void PageProbe::cancel()
{
    if (m_key.isEmpty())
        return;
    m_key.clear();
    disconnectSwap();
    emit stateChanged();
}

void PageProbe::onFrameSwapped()
{
    if (m_key.isEmpty() || m_create < 0)
        return;
    const qint64 t = now();
    if (m_afterAnim < 0 || m_firstSwap < 0) {
        ++m_frames;
        m_maxFrame = qMax(m_maxFrame, t - m_lastFrame);
        m_lastFrame = t;
    }
    if (m_firstSwap < 0)
        m_firstSwap = t;
    finishIfDone();
}

void PageProbe::finishIfDone()
{
    if (m_key.isEmpty() || m_firstSwap < 0 || m_afterAnim < 0)
        return;
    m_lastLine = QStringLiteral("page-open %1 create=%2 firstSwap=%3 afterAnim=%4 frames=%5 maxFrame=%6")
                     .arg(m_key)
                     .arg(m_create)
                     .arg(m_firstSwap)
                     .arg(m_afterAnim)
                     .arg(m_frames)
                     .arg(m_maxFrame);
    qInfo("ruya-shell: %s", qPrintable(m_lastLine));
    ++m_lineCount;
    m_key.clear();
    disconnectSwap();
    emit stateChanged();
}
