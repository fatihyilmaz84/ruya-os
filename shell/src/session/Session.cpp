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
        // The mock knows the profiles of the mock Profiles service.
        backend = std::make_unique<MockSessionBackend>([qmlEngine](const QString &id) {
            auto *profiles = qmlEngine ? qmlEngine->singletonInstance<Profiles *>("RuyaShell", "Profiles") : nullptr;
            if (!profiles)
                return true;
            for (const QVariant &v : profiles->profiles()) {
                if (v.toMap().value(QStringLiteral("id")).toString() == id)
                    return true;
            }
            return false;
        });
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
