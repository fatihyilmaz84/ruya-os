#include "FrameMeter.h"

#include <QMetaMethod>
#include <QMutexLocker>

#include <algorithm>
#include <cmath>

namespace {
// A signal of `object` by its signature, invalid when it has none.
QMetaMethod signalOf(const QObject *object, const char *signature)
{
    if (!object)
        return {};
    const QMetaObject *meta = object->metaObject();
    const int index = meta->indexOfSignal(signature);
    return index >= 0 ? meta->method(index) : QMetaMethod();
}
} // namespace

FrameMeter::FrameMeter(QObject *parent)
    : QObject(parent)
{
    m_clock.start();
}

FrameMeter::~FrameMeter()
{
    disconnectAll();
}

void FrameMeter::setSource(QObject *surface)
{
    if (surface == m_source)
        return;
    QObject::disconnect(m_sourceGone);
    m_source = surface;
    if (surface)
        m_sourceGone = connect(surface, &QObject::destroyed, this, [this] { reconnect(); });
    reconnect();
}

void FrameMeter::setWindow(QObject *window)
{
    if (window == m_window)
        return;
    QObject::disconnect(m_windowGone);
    m_window = window;
    if (window)
        m_windowGone = connect(window, &QObject::destroyed, this, [this] { reconnect(); });
    reconnect();
}

void FrameMeter::setRunning(bool on)
{
    if (on == m_running)
        return;
    m_running = on;
    reconnect();
}

void FrameMeter::setFakeNowMs(double ms)
{
    m_fakeNowNs.store(ms < 0 ? -1 : qint64(ms * 1e6 + 0.5));
}

qint64 FrameMeter::nowNs() const
{
    const qint64 fake = m_fakeNowNs.load();
    return fake >= 0 ? fake : m_clock.nsecsElapsed();
}

void FrameMeter::disconnectAll()
{
    QObject::disconnect(m_commitConnection);
    QObject::disconnect(m_presentConnection);
    m_commitConnection = {};
    m_presentConnection = {};
}

// Connected exactly while running with a surface and a window that have the two signals; a new
// surface (another app in front) starts the count again.
void FrameMeter::reconnect()
{
    disconnectAll();
    const QMetaMethod commit = signalOf(m_source, "redraw()");
    const QMetaMethod present = signalOf(m_window, "frameSwapped()");
    const bool counting = m_running && commit.isValid() && present.isValid();
    {
        QMutexLocker lock(&m_mutex);
        m_pending = false;
        m_presented.clear();
        m_commits.clear();
        m_since = nowNs();
    }
    if (counting) {
        const QMetaObject *meta = metaObject();
        m_commitConnection = connect(m_source, commit, this, meta->method(meta->indexOfSlot("onCommit()")));
        m_presentConnection = connect(m_window, present, this, meta->method(meta->indexOfSlot("onPresented()")),
                                      Qt::DirectConnection);
    }
    if (counting != m_counting) {
        m_counting = counting;
        emit countingChanged();
    }
}

void FrameMeter::prune(QVector<qint64> &stamps, qint64 now)
{
    // Two windows are kept: the frame just before the window gives the first interval in it.
    const qint64 oldest = now - 2 * WindowNs;
    const auto keep = std::find_if(stamps.begin(), stamps.end(), [oldest](qint64 t) { return t >= oldest; });
    stamps.erase(stamps.begin(), keep);
}

void FrameMeter::onCommit()
{
    m_commitsSeen.fetch_add(1);
    const qint64 now = nowNs();
    QMutexLocker lock(&m_mutex);
    m_pending = true;
    m_commits.append(now);
    prune(m_commits, now);
}

void FrameMeter::onPresented()
{
    const qint64 now = nowNs();
    QMutexLocker lock(&m_mutex);
    if (!m_pending)
        return;   // the shell drew, but nothing new of the app was on it
    m_pending = false;
    m_presented.append(now);
    prune(m_presented, now);
}

FrameMeter::Stats FrameMeter::stats() const
{
    Stats out;
    if (!m_counting)
        return out;
    const qint64 now = nowNs();
    const qint64 start = now - WindowNs;
    QVector<qint64> presented;
    QVector<qint64> commits;
    qint64 since = 0;
    {
        QMutexLocker lock(&m_mutex);
        presented = m_presented;
        commits = m_commits;
        since = m_since;
    }
    out.full = now - since >= WindowNs;
    QVector<double> intervals;
    for (int i = 0; i < presented.size(); ++i) {
        if (presented[i] <= start || presented[i] > now)
            continue;
        ++out.frames;
        if (i > 0)
            intervals.append(double(presented[i] - presented[i - 1]) / 1e6);
    }
    for (qint64 t : commits) {
        if (t > start && t <= now)
            ++out.commits;
    }
    if (!intervals.isEmpty()) {
        double sum = 0;
        for (double v : intervals)
            sum += v;
        out.meanMs = sum / intervals.size();
        std::sort(intervals.begin(), intervals.end());
        const int rank = int(std::ceil(0.99 * intervals.size()));   // nearest rank, 1-based
        out.p99Ms = intervals[std::clamp(rank, 1, int(intervals.size())) - 1];
    }
    return out;
}
