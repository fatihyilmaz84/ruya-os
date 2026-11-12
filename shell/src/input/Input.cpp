#include "Input.h"

#include "DBusInputBackend.h"
#include "MockInputBackend.h"

Input::Input(std::unique_ptr<InputBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &InputBackend::routeFinished, this, [this](const QString &status) {
        if (status != QLatin1String("ok"))
            qWarning("ruya-shell: Input1 SetRoute %s answered %s; sent again with the next change",
                     qPrintable(m_route), qPrintable(status));
        if (status == m_status)
            return;
        m_status = status;
        emit statusChanged();
    });
    // A restarted service is in "shell" with no profile (06 §8): tell it again who is in front.
    connect(m_backend.get(), &InputBackend::serviceAppeared, this, [this] {
        if (!m_route.isEmpty())
            send();
    });
}

Input::~Input() = default;

Input *Input::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<InputBackend> backend;
    // Like Network and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockInputBackend>();
    else
        backend = std::make_unique<DBusInputBackend>();
    return new Input(std::move(backend));
}

void Input::setRoute(const QString &route, const QString &instance, const QString &appId, const QString &profile)
{
    const bool same = route == m_route && instance == m_instance && appId == m_appId && profile == m_profile;
    // The same route again: nothing to do while its call is on its way or was answered "ok"; a
    // failed or refused one is sent again.
    if (same && (m_status.isEmpty() || m_status == QLatin1String("ok")))
        return;
    if (!same) {
        m_route = route;
        m_instance = instance;
        m_appId = appId;
        m_profile = profile;
        emit routeChanged();
    }
    send();
}

void Input::send()
{
    if (!m_status.isEmpty()) {
        m_status.clear();
        emit statusChanged();
    }
    m_backend->setRoute(m_route, m_instance, m_appId, m_profile);
}

QVariantList Input::mockCalls() const
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        return mock->calls();
    return {};
}

void Input::mockClearCalls()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->clearCalls();
}

QString Input::mockServiceRoute() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->route() : QString();
}

QString Input::mockServiceInstance() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->instance() : QString();
}

QString Input::mockServiceProfile() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->profile() : QString();
}

bool Input::mockPads() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->pads() : false;
}

int Input::mockPadGeneration() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->padGeneration() : 0;
}

void Input::mockFail(bool fail)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setFail(fail);
}

void Input::mockRestart()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->restart();
}
