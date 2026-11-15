#include "SystemdWatchdog.h"

#include <QCoreApplication>

#include <climits>

#ifdef Q_OS_LINUX
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#endif

SystemdWatchdog::SystemdWatchdog(QObject *parent)
    : QObject(parent)
{
    connect(&m_timer, &QTimer::timeout, this, &SystemdWatchdog::ping);
}

SystemdWatchdog::~SystemdWatchdog()
{
    closeSocket();
}

bool SystemdWatchdog::supported()
{
#ifdef Q_OS_LINUX
    return true;
#else
    return false;
#endif
}

int SystemdWatchdog::interval(const QString &usec, const QString &watchdogPid, qint64 ownPid)
{
    bool ok = false;
    const qulonglong timeout = usec.trimmed().toULongLong(&ok);
    if (!ok || timeout == 0)
        return 0;
    // WATCHDOG_PID names the process the watchdog is for; a child that inherited it is not that one.
    if (!watchdogPid.trimmed().isEmpty()) {
        const qlonglong pid = watchdogPid.trimmed().toLongLong(&ok);
        if (!ok || pid != ownPid)
            return 0;
    }
    const qulonglong ms = timeout / 2 / 1000;
    if (ms == 0)
        return 1;
    return ms > qulonglong(INT_MAX) ? INT_MAX : int(ms);
}

int SystemdWatchdog::intervalFor(const QString &usec, const QString &watchdogPid, double ownPid) const
{
    return interval(usec, watchdogPid, qint64(ownPid));
}

bool SystemdWatchdog::start()
{
    return startWith(qEnvironmentVariable("WATCHDOG_USEC"), qEnvironmentVariable("WATCHDOG_PID"),
                     qEnvironmentVariable("NOTIFY_SOCKET"));
}

bool SystemdWatchdog::startWith(const QString &usec, const QString &watchdogPid, const QString &notifySocket)
{
    stop();
    if (!supported())
        return false;
    const int ms = interval(usec, watchdogPid, QCoreApplication::applicationPid());
    if (ms == 0 || notifySocket.isEmpty())
        return false;
    if (!openSocket(notifySocket))
        return false;
    m_timer.start(ms);
    qInfo("ruya-shell: systemd watchdog every %d ms", ms);
    emit activeChanged();
    // At once, so that a slow first load before the event loop ran counts against the whole
    // WatchdogSec, not against the half that is left until the first tick.
    ping();
    return true;
}

void SystemdWatchdog::stop()
{
    const bool was = m_timer.isActive();
    m_timer.stop();
    closeSocket();
    if (was)
        emit activeChanged();
}

bool SystemdWatchdog::openSocket(const QString &notifySocket)
{
#ifdef Q_OS_LINUX
    const QByteArray path = notifySocket.toLocal8Bit();
    sockaddr_un addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (path.size() >= int(sizeof(addr.sun_path))) {
        qWarning("ruya-shell: systemd watchdog off: NOTIFY_SOCKET is too long");
        return false;
    }
    std::memcpy(addr.sun_path, path.constData(), size_t(path.size()));
    socklen_t length = socklen_t(offsetof(sockaddr_un, sun_path) + size_t(path.size()));
    if (path.startsWith('@'))
        addr.sun_path[0] = '\0'; // an abstract name: no terminating NUL counts
    else
        length += 1;
    m_fd = ::socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (m_fd < 0) {
        qWarning("ruya-shell: systemd watchdog off: no socket: %s", std::strerror(errno));
        return false;
    }
    m_address = QByteArray(reinterpret_cast<const char *>(&addr), int(length));
    return true;
#else
    Q_UNUSED(notifySocket);
    return false;
#endif
}

void SystemdWatchdog::closeSocket()
{
#ifdef Q_OS_LINUX
    if (m_fd >= 0)
        ::close(m_fd);
#endif
    m_fd = -1;
    m_address.clear();
}

void SystemdWatchdog::ping()
{
#ifdef Q_OS_LINUX
    if (m_fd < 0)
        return;
    static const char message[] = "WATCHDOG=1";
    const ssize_t sent = ::sendto(m_fd, message, sizeof(message) - 1, MSG_NOSIGNAL,
                                  reinterpret_cast<const sockaddr *>(m_address.constData()),
                                  socklen_t(m_address.size()));
    ++m_pings;
    if (sent < 0) {
        ++m_failedPings;
        // One warning per run of failures, not one per tick.
        if (!m_warned)
            qWarning("ruya-shell: systemd watchdog: WATCHDOG=1 not sent: %s", std::strerror(errno));
        m_warned = true;
    } else {
        m_warned = false;
    }
    emit pingsChanged();
#endif
}
