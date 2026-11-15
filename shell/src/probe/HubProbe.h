#pragma once

#include <QElapsedTimer>
#include <QMetaObject>
#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QTimer>

#include <atomic>

// What the Ruya Hub costs over a game (RUY-405, 02 section 1.6, ADR-033), measured by the shell for
// scripts/dell-hub-check.sh. The window is the shell's window (anything with a `frameSwapped()` signal)
// and the surface the one of the app in front (anything with `redraw()`, one per commit); both are
// found by signal name, like FrameMeter, so a test stands in for them with a QtObject.
//
// 1. Resume (always on, like PageProbe): begin() when the Hub closes over a frozen game and the shell
//    asks to thaw it, thawAnswered() with Session.thawFinished's reply. One line per Resume:
//      ruya-shell: hub-resume thawReply=<ms> firstFrame=<ms> status=<thaw status>
//    in ms from begin(). firstFrame is the first frame the shell presents after the Thaw reply that
//    follows a commit of the game's surface (the game's next presented frame). A thaw that did not
//    succeed writes the line with its status and no firstFrame; no frame within timeoutMs of the reply
//    (a sleeping display, a game that stays black) writes firstFrame=timeout; no reply in that time
//    writes thawReply=timeout. The connections to the two signals exist only while a Resume is measured.
// 2. Shell-own frames (only with countFrames, which RUYA_PERF_LOG=1 turns on): the presented frames
//    that carry no commit of the game's surface since the previous presented frame. A frame that only
//    presents the game's buffer follows a commit and does not count; a clock or animation that makes
//    the shell draw by itself does. Counted while a surface and a window are set, logged once a second
//      ruya-shell: perf-own frames=<n> window=1s
//    With countFrames off no connection exists and no timer runs.
// Threads: for the own-frame count frameSwapped is connected directly (the render thread in the
// threaded render loop) and only touches atomics; the Resume part runs on the GUI thread.
class HubProbe : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QObject *window READ window WRITE setWindow NOTIFY windowChanged)
    Q_PROPERTY(QObject *surface READ surface WRITE setSurface NOTIFY surfaceChanged)
    Q_PROPERTY(bool countFrames READ countFrames WRITE setCountFrames NOTIFY countingChanged)
    // The shell-own frames are being counted now (countFrames, a window and a surface).
    Q_PROPERTY(bool counting READ counting NOTIFY countingChanged)
    // Shell-own frames counted so far (tests read it).
    Q_PROPERTY(int ownFrames READ ownFrames NOTIFY framesChanged)
    Q_PROPERTY(int timeoutMs READ timeoutMs WRITE setTimeoutMs NOTIFY timeoutMsChanged)
    // A Resume is being measured, the last line written and how many were written.
    Q_PROPERTY(bool pending READ pending NOTIFY stateChanged)
    Q_PROPERTY(QString lastLine READ lastLine NOTIFY stateChanged)
    Q_PROPERTY(int lineCount READ lineCount NOTIFY stateChanged)

public:
    explicit HubProbe(QObject *parent = nullptr);
    ~HubProbe() override;

    QObject *window() const { return m_window; }
    void setWindow(QObject *window);
    QObject *surface() const { return m_surface; }
    void setSurface(QObject *surface);
    bool countFrames() const { return m_countFrames; }
    void setCountFrames(bool on);
    bool counting() const { return m_counting; }
    int ownFrames() const { return m_own.load(); }
    int timeoutMs() const { return m_timeout.interval(); }
    void setTimeoutMs(int ms);
    bool pending() const { return m_pending; }
    QString lastLine() const { return m_lastLine; }
    int lineCount() const { return m_lineCount; }

    // The Hub closed over a frozen game and its Thaw goes out: the clock starts (a second begin()
    // restarts it, the first Resume writes nothing).
    Q_INVOKABLE void begin(const QString &instance);
    // Session.thawFinished: ignored unless it is the instance being measured.
    Q_INVOKABLE void thawAnswered(const QString &instance, const QString &status);
    // The Resume did not happen after all: nothing is written.
    Q_INVOKABLE void cancel();

signals:
    void windowChanged();
    void surfaceChanged();
    void countingChanged();
    void framesChanged();
    void timeoutMsChanged();
    void stateChanged();

private slots:
    void onOwnCommit();
    void onOwnSwap();
    void onResumeCommit();
    void onResumeSwap();

private:
    void reconnect();
    void disconnectAll();
    void finish(const QString &firstFrame);
    void onTimeout();
    void logOwn();
    qint64 now() const { return m_clock.elapsed(); }

    QPointer<QObject> m_window;
    QPointer<QObject> m_surface;
    QMetaObject::Connection m_windowGone;
    QMetaObject::Connection m_surfaceGone;
    QMetaObject::Connection m_ownCommit;
    QMetaObject::Connection m_ownSwap;
    QMetaObject::Connection m_resumeCommit;
    QMetaObject::Connection m_resumeSwap;

    bool m_countFrames = false;
    bool m_counting = false;
    std::atomic<bool> m_commitSeen{false};   // the game committed since the last presented frame
    std::atomic<int> m_own{0};
    int m_ownLogged = 0;
    QTimer m_logTimer;

    QElapsedTimer m_clock;
    QTimer m_timeout;
    bool m_pending = false;
    QString m_instance;
    qint64 m_reply = -1;        // ms of the Thaw reply, -1 none yet, -2 none within the timeout
    QString m_status;
    bool m_armed = false;       // the Thaw was answered "ok": waiting for a commit, then a frame
    bool m_committed = false;   // ... and the commit came
    QString m_lastLine;
    int m_lineCount = 0;
};
