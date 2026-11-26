#include "MockSessionBackend.h"

#include <QDateTime>
#include <QTimer>

namespace {
const QString Crashy = QStringLiteral("crashy");
const QString NoLaunch = QStringLiteral("nolaunch");

const QString FlatpakItem = QStringLiteral("flatpak:");
const QString SteamItem = QStringLiteral("steam:");
// The Steam Flatpak, the parent of every Steam game (ruya-session's STEAM_APP_ID).
const QString SteamAppId = QStringLiteral("com.valvesoftware.Steam");

// The mock apps, Steam, and the .play games of the mock Library (a .play game is a Flatpak app, RUY-905).
bool installed(const QString &appId)
{
    return appId == Crashy || appId == NoLaunch || appId == SteamAppId
           || appId.startsWith(QLatin1String("org.example.")) || appId.startsWith(QLatin1String("play.com.example."));
}

// "steam:<appid>" with 1 to 10 digits, as ruya-ids' parse_item.
bool isSteamItem(const QString &item)
{
    if (!item.startsWith(SteamItem))
        return false;
    const QString appid = item.mid(SteamItem.size());
    if (appid.isEmpty() || appid.size() > 10)
        return false;
    for (const QChar c : appid) {
        if (c < QLatin1Char('0') || c > QLatin1Char('9'))
            return false;
    }
    return true;
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
    m_childWaitMs = ChildLaunchWaitMs;
    m_endingAs.clear();
    m_lastActive = m_activeProfile ? m_activeProfile().value_or(QString()) : QString();
    emit runningListed(m_running);
}

void MockSessionBackend::refresh()
{
    QTimer::singleShot(0, this, [this] { emit runningListed(m_running); });
}

void MockSessionBackend::launch(const QString &appId, const QString &profile)
{
    QString instance;
    const QString status = start(appId, profile, &instance);
    QTimer::singleShot(0, this, [this, appId, profile, status, instance] {
        emit launchFinished(appId, profile, status, instance);
    });
}

void MockSessionBackend::launchItem(const QString &item, const QString &profile)
{
    QString status = QStringLiteral("invalid");
    QString instance;
    if (item.startsWith(FlatpakItem) && item.size() > FlatpakItem.size())
        status = start(item.mid(FlatpakItem.size()), profile, &instance);
    else if (isSteamItem(item))
        status = launchSteamGame(item, profile, &instance);
    QTimer::singleShot(0, this, [this, item, profile, status, instance] {
        emit launchItemFinished(item, profile, status, instance);
    });
}

QString MockSessionBackend::start(const QString &appId, const QString &profile, QString *instance)
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
            if (r.appId == appId && r.profile == profile && r.parent.isEmpty())   // a Steam child is not Steam
                status = QStringLiteral("already-running");
        }
    }
    if (status != QLatin1String("ok"))
        return status;

    RunningApp r;
    r.instance = QStringLiteral("mock-%1.%2").arg(m_next++).arg(appId);
    r.appId = appId;
    r.item = FlatpakItem + appId;
    r.profile = profile;
    r.started = QDateTime::currentSecsSinceEpoch();
    r.pid = 4000 + m_next - 1;
    m_running.append(r);
    *instance = r.instance;
    const QString started = r.instance;
    QTimer::singleShot(m_startMs, this, [this, started] { setRunning(started); });
    return status;
}

QString MockSessionBackend::launchSteamGame(const QString &item, const QString &profile, QString *instance)
{
    // As ruya-session's launch_steam_game (RUY-1067).
    if (profile.isEmpty())
        return QStringLiteral("invalid");
    if (m_knownProfile && !m_knownProfile(profile))
        return QStringLiteral("unknown-profile");
    for (const RunningApp &r : std::as_const(m_running)) {
        if (r.item == item && r.profile == profile) {
            *instance = r.instance;                // starting, running or stopping: that child
            return QStringLiteral("already-running");
        }
    }
    QString parent;
    for (const RunningApp &r : std::as_const(m_running)) {
        if (r.appId == SteamAppId && r.parent.isEmpty() && r.profile == profile && r.state != QLatin1String("stopping"))
            parent = r.instance;
    }
    if (!parent.isEmpty()) {
        m_calls.append(QStringLiteral("forward ") + item);   // the running Steam is handed the game
    } else {
        const QString status = start(SteamAppId, profile, &parent);
        if (status != QLatin1String("ok"))
            return status;
    }
    const QString name = addChild(indexOf(parent), item, QStringLiteral("starting"));
    *instance = name;
    QTimer::singleShot(m_childWaitMs, this, [this, name] {
        const int i = indexOf(name);
        if (i >= 0 && awaitsScope(i))
            exitApp(name, -1, QStringLiteral("launch-failed"));   // its scope never came
    });
    return QStringLiteral("ok");
}

bool MockSessionBackend::awaitsScope(int index) const
{
    const RunningApp &r = m_running.at(index);
    return !r.parent.isEmpty() && r.state == QLatin1String("starting");
}

QString MockSessionBackend::startChild(const QString &parentInstance, const QString &item)
{
    const int p = indexOf(parentInstance);
    if (p < 0 || !m_running.at(p).parent.isEmpty() || m_running.at(p).state != QLatin1String("running")
        || !isSteamItem(item))
        return {};
    for (int i = 0; i < m_running.size(); ++i) {
        const RunningApp &r = m_running.at(i);
        if (r.parent != parentInstance || r.item != item)
            continue;
        if (!awaitsScope(i))
            return {};                             // known already: nothing changes
        // The game LaunchItem asked for got its scope: it runs now (ruya-session's child_started).
        m_running[i].state = QStringLiteral("running");
        const QString instance = r.instance;
        const QString appId = r.appId;
        QTimer::singleShot(0, this, [this, instance, appId] { emit appStarted(instance, appId); });
        return instance;
    }
    const QString instance = addChild(p, item, QStringLiteral("running"));
    const QString appId = m_running.at(p).appId;
    QTimer::singleShot(0, this, [this, instance, appId] { emit appStarted(instance, appId); });
    return instance;
}

QString MockSessionBackend::addChild(int parentIndex, const QString &item, const QString &state)
{
    const RunningApp &p = m_running.at(parentIndex);
    RunningApp child;
    child.instance = QStringLiteral("mock-%1.%2").arg(m_next++).arg(item);
    child.appId = p.appId;
    child.item = item;
    child.parent = p.instance;
    child.profile = p.profile;
    child.started = QDateTime::currentSecsSinceEpoch();
    child.state = state;
    child.pid = 4000 + m_next - 1;
    m_running.append(child);
    return child.instance;
}

void MockSessionBackend::endChild(const QString &instance)
{
    const int i = indexOf(instance);
    if (i >= 0 && !m_running.at(i).parent.isEmpty())
        exitApp(instance, 0, QStringLiteral("quit"));
}

QStringList MockSessionBackend::childrenOf(const QString &instance) const
{
    QStringList children;
    for (const RunningApp &r : std::as_const(m_running)) {
        if (r.parent == instance)
            children.append(r.instance);
    }
    return children;
}

void MockSessionBackend::enterStopping(int index)
{
    if (m_running.at(index).state == QLatin1String("stopping"))
        return;                                 // announced once per entry, as ruya-session does
    m_running[index].state = QStringLiteral("stopping");
    const QString instance = m_running.at(index).instance;
    const QString appId = m_running.at(index).appId;
    QTimer::singleShot(0, this, [this, instance, appId] { emit appStopping(instance, appId); });
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
    if (status == QLatin1String("ok"))
        stopRuns({instance});
}

void MockSessionBackend::stopAll()
{
    QStringList runs;
    for (const RunningApp &r : std::as_const(m_running)) {
        if (r.parent.isEmpty())
            runs.append(r.instance);            // a child is stopped with its parent
    }
    stopRuns(runs);
}

void MockSessionBackend::stopRuns(const QStringList &instances)
{
    // As ruya-session sends a stop's signals (RUY-1235): every instance asked is "stopping" first, children
    // before their parent (AppStopping), then the thaws of the frozen ones (FrozenChanged(false)) and the
    // stops; the runs end later. An instance stopping already is left alone.
    QStringList asked;                          // what is stopped below, children before their parent
    QStringList children;                       // of those, the children of an instance asked
    for (const QString &instance : instances) {
        const int i = indexOf(instance);
        if (i < 0 || m_running.at(i).state == QLatin1String("stopping"))
            continue;
        if (awaitsScope(i)) {
            endStartingChild(i, QStringLiteral("quit"));
            continue;
        }
        for (const QString &child : childrenOf(instance)) {   // ADR-041: the children first
            const int c = indexOf(child);
            if (m_endingAs.contains(child) || m_running.at(c).state == QLatin1String("stopping"))
                continue;
            if (awaitsScope(c)) {
                endStartingChild(c, QStringLiteral("launch-failed"));   // nothing of it to reach (RUY-1067)
                continue;
            }
            enterStopping(c);
            asked.append(child);
            children.append(child);
        }
        enterStopping(i);
        asked.append(instance);
    }
    for (const QString &instance : std::as_const(asked)) {
        const int i = indexOf(instance);
        if (m_running.at(i).frozen) {
            // Like ruya-session: a frozen app is thawed before it is asked to quit.
            m_calls.append(QStringLiteral("thaw ") + instance);
            setFrozen(i, false);
        }
        m_calls.append(QStringLiteral("stop ") + instance);
        if (children.contains(instance)) {
            QTimer::singleShot(0, this, [this, instance] { exitApp(instance, 0, QStringLiteral("quit")); });
            continue;
        }
        if (m_ignoreStop) {
            // The game does not close: the service's backstop kills it (RUY-736), unless Kill came first.
            QTimer::singleShot(BackstopMs, this, [this, instance] { exitApp(instance, 9, QStringLiteral("killed")); });
            continue;
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
    if (awaitsScope(i) || m_endingAs.contains(instance)) {
        endStartingChild(i, QStringLiteral("killed"));
        return;
    }
    // ADR-041: a parent's children are killed first; each is "stopping" (AppStopping) before any end.
    QStringList killed;
    for (const QString &child : childrenOf(instance)) {
        const int c = indexOf(child);
        if (awaitsScope(c) || m_endingAs.contains(child)) {
            if (!m_endingAs.contains(child))
                endStartingChild(c, QStringLiteral("launch-failed"));   // nothing of it to reach (RUY-1067)
            continue;
        }
        m_calls.append(QStringLiteral("kill ") + child);
        enterStopping(c);
        killed.append(child);
    }
    m_calls.append(QStringLiteral("kill ") + instance);
    enterStopping(indexOf(instance));
    for (const QString &child : std::as_const(killed))
        QTimer::singleShot(0, this, [this, child] { exitApp(child, 9, QStringLiteral("killed")); });
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

void MockSessionBackend::endStartingChild(int index, const QString &reason)
{
    // A Steam game still waiting for its scope is ended by ruya-session alone (RUY-1067): no call reaches
    // the OS, it is "stopping" until the next tick, then AppExited with exit code -1. A Kill after a Stop
    // makes it "killed".
    const QString instance = m_running.at(index).instance;
    enterStopping(index);
    const bool queued = m_endingAs.contains(instance);
    m_endingAs.insert(instance, reason);
    if (queued)
        return;
    QTimer::singleShot(0, this, [this, instance] { exitApp(instance, -1, m_endingAs.take(instance)); });
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

void MockSessionBackend::setChildrenFrozen(const QString &parentInstance, bool frozen)
{
    for (int c = 0; c < m_running.size(); ++c) {
        if (m_running.at(c).parent != parentInstance || m_running.at(c).state != QLatin1String("running"))
            continue;
        m_calls.append(QLatin1String(frozen ? "freeze " : "thaw ") + m_running.at(c).instance);
        setFrozen(c, frozen);
    }
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
            if (m_failFreeze) {
                m_calls.append(QStringLiteral("freeze ") + instance);
                status = QStringLiteral("failed");     // undone at once: the app keeps running
            } else {
                setChildrenFrozen(instance, true);     // ADR-041 point 7: the children first
                m_calls.append(QStringLiteral("freeze ") + instance);
                setFrozen(i, true);
            }
        }
    }
    QTimer::singleShot(0, this, [this, instance, status] { emit freezeFinished(instance, status); });
}

void MockSessionBackend::thaw(const QString &instance)
{
    QString status = freezable(instance);
    if (status == QLatin1String("ok")) {
        if (m_failThaw) {
            m_calls.append(QStringLiteral("thaw ") + instance);
            status = QStringLiteral("failed");     // still frozen
        } else {
            setChildrenFrozen(instance, false);
            m_calls.append(QStringLiteral("thaw ") + instance);
            setFrozen(indexOf(instance), false);
        }
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
