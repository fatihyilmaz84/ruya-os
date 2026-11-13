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
    connect(m_backend.get(), &InputBackend::serviceOwnedChanged, this, &Input::serviceOwnedChanged);
    // A restarted service is in "shell" with no profile (06 §8): tell it again who is in front, and
    // ask for its devices.
    connect(m_backend.get(), &InputBackend::serviceAppeared, this, [this] {
        if (!m_route.isEmpty())
            send();
        m_backend->refreshDevices();
    });
    connect(m_backend.get(), &InputBackend::devicesListed, this, [this](bool ok, const QVariantList &devices) {
        if (ok && devices != m_devices) {
            m_devices = devices;
            emit devicesChanged();
        }
        const QString state = ok ? QStringLiteral("ok") : QStringLiteral("failed");
        if (state != m_devicesState) {
            m_devicesState = state;
            emit devicesStateChanged();
        }
    });
    connect(m_backend.get(), &InputBackend::devicesChanged, this, [this] { m_backend->refreshDevices(); });
    connect(m_backend.get(), &InputBackend::capabilitiesFinished, this, &Input::capabilitiesFinished);
    connect(m_backend.get(), &InputBackend::testStartFinished, this, &Input::testStartFinished);
    connect(m_backend.get(), &InputBackend::testInput, this, &Input::testInput);
    connect(m_backend.get(), &InputBackend::testEnded, this, &Input::testEnded);
    m_backend->refreshDevices();
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

void Input::mockNameOwned(bool owned)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setNameOwned(owned);
}

void Input::refreshDevices()
{
    m_backend->refreshDevices();
}

void Input::requestCapabilities(const QString &deviceId)
{
    m_backend->getCapabilities(deviceId);
}

void Input::startTest(const QString &deviceId)
{
    m_backend->startTest(deviceId);
}

void Input::stopTest(const QString &deviceId)
{
    m_backend->stopTest(deviceId);
}

void Input::mockAddDevice(const QVariantMap &device)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->addDevice(device);
}

void Input::mockRemoveDevice(const QString &id)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->removeDevice(id);
}

void Input::mockListFail(bool fail)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setListFail(fail);
}

void Input::mockTestInput(const QString &id, const QString &input, int value, const QString &source)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->sendTestInput(id, input, value, source);
}

void Input::mockEndTest(const QString &id, const QString &reason)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->endTest(id, reason);
}

bool Input::mockTestRunning(const QString &id) const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->testRunning(id) : false;
}

void Input::mockResetDevices()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->resetDevices();
}
