#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QTimer>

// The systemd watchdog of the shell (RUY-483, 01 section 2): ruya-compositor@.service has
// WatchdogSec=30s, and this object sends WATCHDOG=1 to NOTIFY_SOCKET every WATCHDOG_USEC / 2 from a
// QTimer on the GUI thread, so a GUI thread that stops (a wedged event loop) stops the pings and
// systemd restarts the unit. Never ping from another thread: that would hide exactly that wedge.
//   start()     reads WATCHDOG_USEC, WATCHDOG_PID and NOTIFY_SOCKET (main.cpp, once the event loop
//               runs); pings once at once, then on the timer. Unset, 0, garbage, a WATCHDOG_PID that is
//               not ours, no NOTIFY_SOCKET, or not Linux: nothing runs (the mock, the tests, Windows).
//   active      the timer runs; intervalMs is its period (0 while off)
//   pings       WATCHDOG=1 sends tried; a failing send logs one warning, not one per tick
// The journal says "ruya-shell: systemd watchdog every <n> ms" when it starts, nothing when off.
// No libsystemd: the datagram is the whole sd_notify protocol (sd_notify(3); a leading '@' is an
// abstract socket name), as in services/ruya-inputd/src/notify.rs.
class SystemdWatchdog : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    Q_PROPERTY(int intervalMs READ intervalMs NOTIFY activeChanged)
    Q_PROPERTY(int pings READ pings NOTIFY pingsChanged)
    Q_PROPERTY(int failedPings READ failedPings NOTIFY pingsChanged)
    // The platform can send at all (Linux); off it, start() never runs a timer.
    Q_PROPERTY(bool supported READ supported CONSTANT)

public:
    explicit SystemdWatchdog(QObject *parent = nullptr);
    ~SystemdWatchdog() override;

    bool active() const { return m_timer.isActive(); }
    int intervalMs() const { return m_timer.isActive() ? m_timer.interval() : 0; }
    int pings() const { return m_pings; }
    int failedPings() const { return m_failedPings; }
    static bool supported();

    // The rule (sd_watchdog_enabled(3)): half of usec, in milliseconds (at least 1); 0 = off when usec
    // is empty, 0 or not a number, or when watchdogPid is set and is not ownPid.
    static int interval(const QString &usec, const QString &watchdogPid, qint64 ownPid);
    // Tests: the rule above, reachable from QML.
    Q_INVOKABLE int intervalFor(const QString &usec, const QString &watchdogPid, double ownPid) const;

    // From the environment of this process (WATCHDOG_USEC, WATCHDOG_PID, NOTIFY_SOCKET).
    Q_INVOKABLE bool start();
    // Tests: start() with these values instead of the environment (this process's pid is ours).
    Q_INVOKABLE bool startWith(const QString &usec, const QString &watchdogPid, const QString &notifySocket);
    Q_INVOKABLE void stop();

signals:
    void activeChanged();
    void pingsChanged();

private:
    void ping();
    bool openSocket(const QString &notifySocket);
    void closeSocket();

    QTimer m_timer;
    int m_pings = 0;
    int m_failedPings = 0;
    bool m_warned = false;
    int m_fd = -1;
    QByteArray m_address; // a struct sockaddr_un, as many bytes as sendto() gets
};
