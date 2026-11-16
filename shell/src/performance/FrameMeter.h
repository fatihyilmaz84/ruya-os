#pragma once

#include <QElapsedTimer>
#include <QMetaObject>
#include <QMutex>
#include <QObject>
#include <QPointer>
#include <QVector>

#include <atomic>

// FPS and frame time of the app in front (T-451, ADR-033 point 4), measured by the compositor:
// the app surface's commits (the surface's `redraw()` signal, one per wl_surface.commit) and the
// shell's own presented frames (the window's `frameSwapped()`). A presented frame counts as a new
// frame of the app when the app committed since the frame before, so the number is what the
// player sees: a game that commits 120 times a second on a 60 Hz display shows 60, and one that
// stalls shows fewer, however fast the shell itself draws.
//
// Zero cost while nobody looks: the meter connects to the two signals only while it runs (a
// Performance consumer is open) and both a surface and a window are set; otherwise no signal
// reaches it and nothing is counted (`commitsSeen` stays put, a test reads it). The source and the
// window are plain QObjects found by signal name, so a test can stand in for both with a
// QtObject that has `signal redraw()` and `signal frameSwapped()`.
//
// Threads: `frameSwapped` comes from the render thread in the threaded render loop. It is
// connected directly and only takes a timestamp under a mutex; everything else runs on the GUI
// thread. Time is a monotonic clock, or `setFakeNowMs` (tests).
class FrameMeter : public QObject
{
    Q_OBJECT
public:
    // Over the last second, ending now.
    struct Stats {
        bool full = false;     // counting has run for at least a whole second
        int frames = 0;        // presented frames with new app content
        // The intervals that end in the window (the first one may start before it): their mean
        // and 99th percentile (nearest rank), ms; -1 when no frame or only the very first one.
        double meanMs = -1;
        double p99Ms = -1;
        int commits = 0;       // the app's commits
        // The lows over the rolling LowWindowNs of the front app's frame intervals (RUY-738): the
        // 99th and 99.9th percentile interval (nearest rank), ms; -1 below MinFor1Low / MinFor01Low
        // intervals. `lowIntervals` is how many the window holds.
        int lowIntervals = 0;
        double low1Ms = -1;
        double low01Ms = -1;
    };

    static constexpr qint64 LowWindowNs = 60LL * 1000 * 1000 * 1000;
    static constexpr int MaxLowIntervals = 21600;   // 60 s at 360 fps
    static constexpr int MinFor1Low = 100;
    static constexpr int MinFor01Low = 1000;

    static constexpr qint64 WindowNs = 1000LL * 1000 * 1000;

    explicit FrameMeter(QObject *parent = nullptr);
    ~FrameMeter() override;

    QObject *source() const { return m_source; }
    QObject *window() const { return m_window; }
    void setSource(QObject *surface);
    void setWindow(QObject *window);
    void setRunning(bool on);
    bool counting() const { return m_counting; }
    int commitsSeen() const { return m_commitsSeen.load(); }
    // ms on a test clock; a negative value goes back to the real clock.
    void setFakeNowMs(double ms);
    Stats stats() const;

signals:
    void countingChanged();

private slots:
    void onCommit();
    void onPresented();

private:
    void reconnect(bool resetLows = true);
    void disconnectAll();
    qint64 nowNs() const;
    static void prune(QVector<qint64> &stamps, qint64 now);

    QPointer<QObject> m_source;
    QPointer<QObject> m_window;
    QMetaObject::Connection m_commitConnection;
    QMetaObject::Connection m_presentConnection;
    QMetaObject::Connection m_sourceGone;
    QMetaObject::Connection m_windowGone;
    bool m_running = false;
    bool m_counting = false;
    QElapsedTimer m_clock;
    std::atomic<qint64> m_fakeNowNs{-1};
    std::atomic<int> m_commitsSeen{0};

    mutable QMutex m_mutex;          // guards what follows (onPresented may run on the render thread)
    bool m_pending = false;          // the app committed since the last presented frame
    qint64 m_since = 0;              // when counting started
    QVector<qint64> m_presented;     // timestamps (ns) of presented new frames, the last two seconds
    QVector<qint64> m_commits;       // timestamps (ns) of commits, the last two seconds
    // The rolling LowWindowNs of intervals (RUY-738): when each ended, and its length (ns). Cleared
    // when the surface or window changes; kept over a pause (running off and on), where only the
    // interval across the gap is dropped (`m_lastFrame` back to -1).
    QVector<qint64> m_lowEnds;
    QVector<qint64> m_lowIntervals;
    qint64 m_lastFrame = -1;         // the previous presented frame, -1 when none counts
};
