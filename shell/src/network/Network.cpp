#include "Network.h"

#include "DBusNetworkBackend.h"
#include "MockNetworkBackend.h"

Network::Network(std::unique_ptr<NetworkBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &NetworkBackend::stateChanged, this, [this](const QString &state, const QVariantMap &primary) {
        if (state == m_state && primary == m_primary)
            return;
        m_state = state;
        m_primary = primary;
        emit stateChanged();
    });
    connect(m_backend.get(), &NetworkBackend::networksListed, this, [this](const QList<WifiInfo> &list) {
        QVariantList out;
        for (const WifiInfo &n : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), n.id},
                {QStringLiteral("ssid"), n.ssid},
                {QStringLiteral("signal"), n.signal},
                {QStringLiteral("security"), n.security},
                {QStringLiteral("known"), n.known},
                {QStringLiteral("active"), n.active},
            });
        }
        m_networks = out;
        emit networksChanged();
    });
    connect(m_backend.get(), &NetworkBackend::connectFinished, this, &Network::connectFinished);
    connect(m_backend.get(), &NetworkBackend::forgetFinished, this, &Network::forgetFinished);
    m_backend->refresh();
}

Network::~Network() = default;

Network *Network::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<NetworkBackend> backend;
    // Like Audio and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockNetworkBackend>();
    else
        backend = std::make_unique<DBusNetworkBackend>();
    return new Network(std::move(backend));
}

void Network::scan()
{
    m_backend->scan();
}

void Network::connectWifi(const QString &id, const QString &password)
{
    m_backend->connectWifi(id, password);
}

void Network::forget(const QString &id)
{
    m_backend->forget(id);
}

QString Network::mockPassword() const
{
    return MockNetworkBackend::password();
}

void Network::mockSetCable(bool plugged)
{
    if (auto *mock = qobject_cast<MockNetworkBackend *>(m_backend.get()))
        mock->setCable(plugged);
}

void Network::mockReset()
{
    if (auto *mock = qobject_cast<MockNetworkBackend *>(m_backend.get()))
        mock->reset();
}
