#pragma once

#include "BluetoothBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Devices1.Bluetooth (api/dbus/org.ruyaos.Devices1.xml) on the system
// bus, or the session bus when RUYA_DBUS=session. The service may start after the shell, so
// the state is read again whenever the name appears. Unverified: no service exists yet (T-132).
class DBusBluetoothBackend final : public BluetoothBackend
{
    Q_OBJECT

public:
    explicit DBusBluetoothBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void setPowered(bool on) override;
    void startScan() override;
    void stopScan() override;
    void pair(const QString &id) override;
    void forget(const QString &id) override;
    void connectDevice(const QString &id) override;
    void disconnectDevice(const QString &id) override;
    void reportIdle(int idleSeconds, int timeoutSeconds, bool hold) override;
    void rename(const QString &id, const QString &name) override;
    void startControllerPairing(int seconds) override;
    void stopControllerPairing() override;

private slots:
    void onDevicesChanged();
    void onControllerRejected();
    void onGamepadConnected(const QString &id, const QString &name, const QString &family, const QString &transport);
    void onGamepadDisconnected(const QString &id, const QString &name, const QString &family, const QString &transport);
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    void refreshState();
    void refreshDevices();
    // Every command answers one status string; op names the finished() signal's operation.
    void startCommand(const QString &method, const QString &op, const QString &id, const QVariantList &args);

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
