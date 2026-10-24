#include "MockNetworkBackend.h"

#include <QTimer>

MockNetworkBackend::MockNetworkBackend(QObject *parent)
    : NetworkBackend(parent)
{
    initState();
}

void MockNetworkBackend::refresh()
{
    publishState();
    publishNetworks();
}

void MockNetworkBackend::scan()
{
    publishNetworks();
}

void MockNetworkBackend::connectWifi(const QString &id, const QString &password)
{
    QString status = QStringLiteral("ok");
    const int at = indexOf(id);
    if (at < 0) {
        status = QStringLiteral("unknown-network");
    } else if (m_networks.at(at).security == QLatin1String("enterprise")) {
        status = QStringLiteral("unsupported");
    } else if (m_networks.at(at).security == QLatin1String("wpa-psk") && !m_networks.at(at).known) {
        if (password.isEmpty())
            status = QStringLiteral("invalid");
        else if (password != MockNetworkBackend::password())
            status = QStringLiteral("wrong-password");
    }
    if (status == QLatin1String("ok")) {
        for (WifiInfo &n : m_networks)
            n.active = false;
        m_networks[at].active = true;
        m_networks[at].known = true; // a successful join saves the network
        publishState();
        publishNetworks();
    }
    QTimer::singleShot(0, this, [this, id, status] { emit connectFinished(id, status); });
}

void MockNetworkBackend::forget(const QString &id)
{
    const int at = indexOf(id);
    if (at >= 0) {
        m_networks[at].known = false;
        m_networks[at].active = false;
        publishState();
        publishNetworks();
    }
    const QString status = at >= 0 ? QStringLiteral("ok") : QStringLiteral("unknown-network");
    QTimer::singleShot(0, this, [this, id, status] { emit forgetFinished(id, status); });
}

void MockNetworkBackend::setCable(bool plugged)
{
    m_cable = plugged;
    publishState();
}

void MockNetworkBackend::reset()
{
    initState();
    publishState();
    publishNetworks();
}

// No publishing here: the constructor runs before anybody listens.
void MockNetworkBackend::initState()
{
    m_cable = true;
    m_networks = {
        {QStringLiteral("wifi-lounge"), QStringLiteral("Lounge 5G"), 82, QStringLiteral("wpa-psk"), true, false},
        {QStringLiteral("wifi-home"), QStringLiteral("HomeNet"), 64, QStringLiteral("wpa-psk"), false, false},
        {QStringLiteral("wifi-cafe"), QStringLiteral("Cafe Guest"), 40, QStringLiteral("open"), false, false},
        {QStringLiteral("wifi-campus"), QStringLiteral("Campus"), 30, QStringLiteral("enterprise"), false, false},
    };
}

int MockNetworkBackend::indexOf(const QString &id) const
{
    for (int i = 0; i < m_networks.size(); ++i) {
        if (m_networks.at(i).id == id)
            return i;
    }
    return -1;
}

// Asynchronous like the real service, so QML behaves the same with either backend. A cable
// wins over Wi-Fi as the primary connection.
void MockNetworkBackend::publishState()
{
    QString state = QStringLiteral("disconnected");
    QVariantMap primary;
    if (m_cable) {
        state = QStringLiteral("connected");
        primary = {{QStringLiteral("kind"), QStringLiteral("ethernet")},
                   {QStringLiteral("name"), QStringLiteral("Wired")},
                   {QStringLiteral("ip"), QStringLiteral("192.168.1.20")}};
    } else {
        for (const WifiInfo &n : std::as_const(m_networks)) {
            if (n.active) {
                state = QStringLiteral("connected");
                primary = {{QStringLiteral("kind"), QStringLiteral("wifi")},
                           {QStringLiteral("name"), n.ssid},
                           {QStringLiteral("ip"), QStringLiteral("192.168.1.21")},
                           {QStringLiteral("signal"), n.signal}};
            }
        }
    }
    QTimer::singleShot(0, this, [this, state, primary] { emit stateChanged(state, primary); });
}

void MockNetworkBackend::publishNetworks()
{
    const QList<WifiInfo> networks = m_networks;
    QTimer::singleShot(0, this, [this, networks] { emit networksListed(networks); });
}
