#include "MockSessionBackend.h"

#include <QDateTime>
#include <QTimer>

namespace {
const QString Crashy = QStringLiteral("crashy");
const QString NoLaunch = QStringLiteral("nolaunch");

// The mock apps, and the .play games of the mock Library (a .play game is a Flatpak app, RUY-905).
bool installed(const QString &appId)
{
    return appId == Crashy || appId == NoLaunch || appId.startsWith(QLatin1String("org.example."))
           || appId.startsWith(QLatin1String("play.com.example."));
}
} // namespace

MockSessionBackend::MockSessionBackend(ProfileCheck knownProfile, ActiveProfile activeProfile, QObject *parent)
    : SessionBackend(parent)
    , m_knownProfile(std::move(knownProfile))
    , m_activeProfile(std::move(activeProfile))
{
    if (qEnvironmentVariable("RUYA_MOCK_FAST") == QLatin1String("1"))
        m_startMs = 10;
}

void MockSessionBackend::activeProfileChanged()
{
    const std::optional<QString> active = m_activeProfile ? m_activeProfile() : std::nullopt;
    if (!active)
        return;
    const QString old = m_lastActive;
    m_lastActive = *active;
    if (old.isEmpty() || old == *active)
        return;
    for (int i = 0; i < m_running.size(); ++i) {
        const RunningApp &r = m_running.at(i);
        if (r.profile != old || r.frozen || r.state != QLatin1String("running"))
            continue;
        m_calls.append(QStringLiteral("freeze ") + r.instance);
        if (!m_failFreeze)                  // a failed freeze is undone: the app keeps running
            setFrozen(i, true);
    }
}

int MockSessionBackend::indexOf(const QString &instance) const
{
    for (int i = 0; i < m_running.size(); ++i) {
        if (m_running.at(i).instance == instance)
            return i;
    }
    return -1;
}

void MockSessionBackend::reset()
{
    m_running.clear();
    m_calls.clear();
    m_failFreeze = false;
    m_failThaw = false;
    m_pidDelayMs = 0;
    m_stopDelayMs = -1;
    m_stubbornStop = false;
    m_ignoreStop = false;
    m_killAnswer.clear();
    m_lastActive = m_activeProfile ? m_activeProfile().value_or(QString()) : QString();
    emit runningListed(m_running);
}

void MockSessionBackend::refresh()
{
    QTimer::singleShot(0, this, [this] { emit runningListed(m_running); });
}

void MockSessionBackend::launch(const QString &appId, const QString &profile)
{
    QString status = QStringLiteral("ok");
    if (appId.isEmpty() || profile.isEmpty())
        status = QStringLiteral("invalid");
    else if (!installed(appId))
        status = QStringLiteral("unknown-app");
    else if (m_knownProfile && !m_knownProfile(profile))
        status = QStringLiteral("unknown-profile");
    else {
        for (const RunningApp &r : std::as_const(m_running)) {
            if (r.appId == appId && r.profile == profile)
                status = QStringLiteral("already-running");
        }
    }
    if (status != QLatin1String("ok")) {
        QTimer::singleShot(0, this, [this, appId, profile, status] { emit launchFinished(appId, profile, status, {}); });
        return;
    }

    RunningApp r;
    r.instance = QStringLiteral("mock-%1.%2").arg(m_next++).arg(appId);
    r.appId = appId;
    r.profile = profile;
    r.started = QDateTime::currentSecsSinceEpoch();
    r.pid = 4000 + m_next - 1;
    m_running.append(r);
    const QString instance = r.instance;
    QTimer::singleShot(0, this, [this, appId, profile, instance] {
        emit launchFinished(appId, profile, QStringLiteral("ok"), instance);
    });
    QTimer::singleShot(m_startMs, this, [this, instance] { setRunning(instance); });
}

void MockSessionBackend::setRunning(const QString &instance)
{
    const int i = indexOf(instance);
    if (i < 0 || m_running.at(i).state != QLatin1String("starting"))
        return; // stopped while it was starting
    if (m_running.at(i).appId == NoLaunch) {
        exitApp(instance, -1, QStringLiteral("launch-failed"));
        return;
    }
    m_running[i].state = QStringLiteral("running");
    emit appStarted(instance, m_running.at(i).appId);
    if (m_running.at(i).appId == Crashy)
        QTimer::singleShot(m_startMs / 3, this, [this, instance] { exitApp(instance, 139, QStringLiteral("crashed")); });
}

void MockSessionBackend::exitApp(const QString &instance, int code, const QString &reason)
{
    const int i = indexOf(instance);
    if (i < 0)
        return;
    const QString appId = m_running.at(i).appId;
    m_running.removeAt(i);
    emit appExited(instance, appId, code, reason);
}

void MockSessionBackend::stop(const QString &instance)
{
    QString status = QStringLiteral("ok");
    const int i = indexOf(instance);
    if (instance.isEmpty())
        status = QStringLiteral("invalid");
    else if (i < 0)
        status = QStringLiteral("unknown-instance");
    QTimer::singleShot(0, this, [this, instance, status] { emit stopFinished(instance, status); });
    if (status != QLatin1String("ok") || m_running.at(i).state == QLatin1String("stopping"))
        return;
    if (m_running.at(i).frozen) {
        // Like ruya-session: a frozen app is thawed before it is asked to quit.
        m_calls.append(QStringLiteral("thaw ") + instance);
        setFrozen(i, false);
    }
    m_calls.append(QStringLiteral("stop ") + instance);
    m_running[i].state = QStringLiteral("stopping");
    if (m_ignoreStop) {
        // The game does not close: the service's backstop kills it (RUY-736), unless Kill came first.
        QTimer::singleShot(BackstopMs, this, [this, instance] { exitApp(instance, 9, QStringLiteral("killed")); });
        return;
    }
    const int delay = m_stopDelayMs >= 0 ? m_stopDelayMs : m_startMs / 3;
    QTimer::singleShot(delay, this, [this, instance] {
        if (!m_stubbornStop) {
            exitApp(instance, 0, QStringLiteral("quit"));
            return;
        }
        // Killed after the grace, and still listed (T-458): the service said "killed" but the record stays.
        const int j = indexOf(instance);
        if (j >= 0)
            emit appExited(instance, m_running.at(j).appId, 137, QStringLiteral("killed"));
    });
}

void MockSessionBackend::kill(const QString &instance)
{
    const int i = indexOf(instance);
    QString status = QStringLiteral("ok");
    if (!m_killAnswer.isEmpty())
        status = m_killAnswer;
    else if (i < 0)
        status = QStringLiteral("unknown-instance");
    else if (m_activeProfile) {
        const std::optional<QString> active = m_activeProfile();
        if (active && (active->isEmpty() || *active != m_running.at(i).profile))
            status = QStringLiteral("not-allowed");
    }
    QTimer::singleShot(0, this, [this, instance, status] { emit killFinished(instance, status); });
    if (status != QLatin1String("ok") || !m_killAnswer.isEmpty())
        return;                         // refused, or the forced answer: nothing is killed
    m_calls.append(QStringLiteral("kill ") + instance);
    m_running[i].state = QStringLiteral("stopping");
    QTimer::singleShot(0, this, [this, instance] {
        if (!m_stubbornStop) {
            exitApp(instance, 9, QStringLiteral("killed"));
            return;
        }
        const int j = indexOf(instance);   // killed, and still listed (the killCheckMs warning, T-458)
        if (j >= 0)
            emit appExited(instance, m_running.at(j).appId, 9, QStringLiteral("killed"));
    });
}

QString MockSessionBackend::freezable(const QString &instance) const
{
    if (instance.isEmpty())
        return QStringLiteral("invalid");
    const int i = indexOf(instance);
    if (i < 0)
        return QStringLiteral("not-running");
    if (m_activeProfile) {
        const std::optional<QString> active = m_activeProfile();
        if (active && (active->isEmpty() || *active != m_running.at(i).profile))
            return QStringLiteral("not-allowed");
    }
    if (m_running.at(i).state != QLatin1String("running"))
        return QStringLiteral("not-running");
    return QStringLiteral("ok");
}

void MockSessionBackend::setFrozen(int index, bool frozen)
{
    if (m_running.at(index).frozen == frozen)
        return;
    m_running[index].frozen = frozen;
    const QString instance = m_running.at(index).instance;
    QTimer::singleShot(0, this, [this, instance, frozen] { emit frozenChanged(instance, frozen); });
}

void MockSessionBackend::freeze(const QString &instance)
{
    QString status = freezable(instance);
    if (status == QLatin1String("ok")) {
        const int i = indexOf(instance);
        if (!m_running.at(i).frozen) {
            m_calls.append(QStringLiteral("freeze ") + instance);
            if (m_failFreeze)
                status = QStringLiteral("failed");     // undone at once: the app keeps running
            else
                setFrozen(i, true);
        }
    }
    QTimer::singleShot(0, this, [this, instance, status] { emit freezeFinished(instance, status); });
}

void MockSessionBackend::thaw(const QString &instance)
{
    QString status = freezable(instance);
    if (status == QLatin1String("ok")) {
        m_calls.append(QStringLiteral("thaw ") + instance);
        if (m_failThaw)
            status = QStringLiteral("failed");     // still frozen
        else
            setFrozen(indexOf(instance), false);
    }
    QTimer::singleShot(0, this, [this, instance, status] { emit thawFinished(instance, status); });
}

int MockSessionBackend::pidOf(const QString &instance) const
{
    const int i = indexOf(instance);
    return i < 0 ? 0 : m_running.at(i).pid;
}

void MockSessionBackend::instanceOfPid(int pid)
{
    QString status = pid <= 0 ? QStringLiteral("invalid") : QStringLiteral("not-found");
    QString instance;
    for (const RunningApp &r : std::as_const(m_running)) {
        if (pid > 0 && r.pid == pid) {
            status = QStringLiteral("ok");
            instance = r.instance;
        }
    }
    QTimer::singleShot(m_pidDelayMs, this, [this, pid, status, instance] { emit instanceOfPidFinished(pid, status, instance); });
}
