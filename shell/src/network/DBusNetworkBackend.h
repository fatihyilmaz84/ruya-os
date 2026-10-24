#pragma once

#include "NetworkBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Devices1.Network (api/dbus/org.ruyaos.Devices1.xml) on the system bus,
// or the session bus when RUYA_DBUS=session. The service may start after the shell, so the
// state is read again whenever the name appears.
class DBusNetworkBackend final : public NetworkBackend
{
    Q_OBJECT

public:
    explicit DBusNetworkBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void scan() override;
    void connectWifi(const QString &id, const QString &password) override;
    void forget(const QString &id) override;

private slots:
    void onNetworksChanged();
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    void refreshState();
    void refreshNetworks();
    // Connect and Forget both answer one status string.
    void startCommand(const QString &method, const QString &id, const QVariantList &args, bool isConnect);

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
