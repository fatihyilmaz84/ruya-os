#pragma once

#include "InputBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Input1 (api/dbus/org.ruyaos.Input1.xml) on the system bus, or the session
// bus when RUYA_DBUS=session. The service may start after the shell or restart under it (systemd
// restarts it within 100 ms, 06 §8): every new owner of the name is reported as serviceAppeared, and
// whether the name has an owner at all as serviceOwned (RUY-410, the emergency reader).
class DBusInputBackend final : public InputBackend
{
    Q_OBJECT

public:
    explicit DBusInputBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void setRoute(const QString &route, const QString &instance, const QString &appId,
                  const QString &profile) override;
    void refreshDevices() override;
    void getCapabilities(const QString &deviceId) override;
    void startTest(const QString &deviceId) override;
    void stopTest(const QString &deviceId) override;
    void callProfile(quint64 token, const QString &method, const QVariantMap &args) override;

private slots:
    void onDevicesChanged();
    void onTestInput(const QString &deviceId, const QString &input, int value, const QString &source);
    void onTestEnded(const QString &deviceId, const QString &reason);
    void onProfilesChanged(const QString &profile);

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
    bool m_ownerSeen = false;
};
