#include "MockSessionBackend.h"

#include <QDateTime>
#include <QTimer>

namespace {
const QString Crashy = QStringLiteral("crashy");

bool installed(const QString &appId)
{
    return appId == Crashy || appId.startsWith(QLatin1String("org.example."));
}
} // namespace

MockSessionBackend::MockSessionBackend(ProfileCheck knownProfile, QObject *parent)
    : SessionBackend(parent)
    , m_knownProfile(std::move(knownProfile))
{
    if (qEnvironmentVariable("RUYA_MOCK_FAST") == QLatin1String("1"))
        m_startMs = 10;
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
    m_running[i].state = QStringLiteral("stopping");
    QTimer::singleShot(m_startMs / 3, this, [this, instance] { exitApp(instance, 0, QStringLiteral("quit")); });
}
