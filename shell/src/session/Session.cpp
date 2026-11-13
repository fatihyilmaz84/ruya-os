#include "Session.h"

#include "DBusSessionBackend.h"
#include "MockSessionBackend.h"
#include "Profiles.h"

Session::Session(std::unique_ptr<SessionBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &SessionBackend::runningListed, this, [this](const QList<RunningApp> &apps) {
        QVariantList list;
        for (const RunningApp &a : apps)
            list.append(a.toVariant());
        m_running = list;
        emit runningChanged();
    });
    connect(m_backend.get(), &SessionBackend::launchFinished, this,
            [this](const QString &appId, const QString &profile, const QString &status, const QString &instance) {
                if (status == QLatin1String("ok"))
                    m_backend->refresh();
                emit launchFinished(appId, profile, status, instance);
            });
    connect(m_backend.get(), &SessionBackend::stopFinished, this, &Session::stopFinished);
    connect(m_backend.get(), &SessionBackend::freezeFinished, this, &Session::freezeFinished);
    connect(m_backend.get(), &SessionBackend::thawFinished, this, &Session::thawFinished);
    connect(m_backend.get(), &SessionBackend::instanceOfPidFinished, this, &Session::instanceOfPidFinished);
    // The record changes in place, so a binding on `running` sees the new `frozen` at once.
    connect(m_backend.get(), &SessionBackend::frozenChanged, this, [this](const QString &instance, bool frozen) {
        for (QVariant &v : m_running) {
            QVariantMap m = v.toMap();
            if (m.value(QStringLiteral("instance")).toString() != instance)
                continue;
            if (m.value(QStringLiteral("frozen")).toBool() != frozen) {
                m.insert(QStringLiteral("frozen"), frozen);
                v = m;
                emit runningChanged();
            }
            break;
        }
        emit frozenChanged(instance, frozen);
    });
    connect(m_backend.get(), &SessionBackend::appStarted, this, [this](const QString &instance, const QString &appId) {
        m_backend->refresh();
        emit appStarted(instance, appId);
    });
    connect(m_backend.get(), &SessionBackend::appExited, this,
            [this](const QString &instance, const QString &appId, int exitCode, const QString &reason) {
                m_backend->refresh();
                emit appExited(instance, appId, exitCode, reason);
            });
    m_backend->refresh();
}

Session::~Session() = default;

Session *Session::create(QQmlEngine *qmlEngine, QJSEngine *)
{
    std::unique_ptr<SessionBackend> backend;
    // Like Store and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock) {
        // The mock knows the profiles of the mock Profiles service, and who is signed in (Freeze).
        backend = std::make_unique<MockSessionBackend>(
            [qmlEngine](const QString &id) {
                auto *profiles = qmlEngine ? qmlEngine->singletonInstance<Profiles *>("RuyaShell", "Profiles") : nullptr;
                if (!profiles)
                    return true;
                for (const QVariant &v : profiles->profiles()) {
                    if (v.toMap().value(QStringLiteral("id")).toString() == id)
                        return true;
                }
                return false;
            },
            [qmlEngine]() -> std::optional<QString> {
                auto *profiles = qmlEngine ? qmlEngine->singletonInstance<Profiles *>("RuyaShell", "Profiles") : nullptr;
                if (!profiles)
                    return std::nullopt;
                return profiles->activeProfile();
            });
        // Like ruya-session (T-165): a profile that leaves has its apps frozen.
        auto *mock = static_cast<MockSessionBackend *>(backend.get());
        if (auto *profiles = qmlEngine ? qmlEngine->singletonInstance<Profiles *>("RuyaShell", "Profiles") : nullptr) {
            QObject::connect(profiles, &Profiles::activeProfileChanged, mock, &MockSessionBackend::activeProfileChanged);
            mock->activeProfileChanged();       // who is signed in now; nothing to freeze yet
        }
    } else {
        backend = std::make_unique<DBusSessionBackend>();
    }
    return new Session(std::move(backend));
}

void Session::launch(const QString &appId, const QString &profile)
{
    m_backend->launch(appId, profile);
}

void Session::stop(const QString &instance)
{
    m_backend->stop(instance);
}

void Session::freeze(const QString &instance)
{
    m_backend->freeze(instance);
}

void Session::thaw(const QString &instance)
{
    m_backend->thaw(instance);
}

void Session::instanceOfPid(int pid)
{
    m_backend->instanceOfPid(pid);
}

void Session::mockDelayPidAnswers(int ms)
{
    if (auto *mock = qobject_cast<MockSessionBackend *>(m_backend.get()))
        mock->setPidAnswerDelay(ms);
}

void Session::mockStopDelay(int ms)
{
    if (auto *mock = qobject_cast<MockSessionBackend *>(m_backend.get()))
        mock->setStopDelay(ms);
}

void Session::mockStubbornStop(bool stubborn)
{
    if (auto *mock = qobject_cast<MockSessionBackend *>(m_backend.get()))
        mock->setStubbornStop(stubborn);
}

int Session::mockPidOf(const QString &instance) const
{
    if (auto *mock = qobject_cast<MockSessionBackend *>(m_backend.get()))
        return mock->pidOf(instance);
    return 0;
}

QVariantMap Session::instanceOf(const QString &appId, const QString &profile) const
{
    for (const QVariant &v : m_running) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("appId")).toString() == appId && m.value(QStringLiteral("profile")).toString() == profile)
            return m;
    }
    return {};
}

void Session::mockReset()
{
    if (auto *mock = qobject_cast<MockSessionBackend *>(m_backend.get()))
        mock->reset();
}

void Session::mockFailFreeze(bool fail)
{
    if (auto *mock = qobject_cast<MockSessionBackend *>(m_backend.get()))
        mock->setFailFreeze(fail);
}

void Session::mockFailThaw(bool fail)
{
    if (auto *mock = qobject_cast<MockSessionBackend *>(m_backend.get()))
        mock->setFailThaw(fail);
}

QStringList Session::mockCalls() const
{
    if (auto *mock = qobject_cast<MockSessionBackend *>(m_backend.get()))
        return mock->calls();
    return {};
}
