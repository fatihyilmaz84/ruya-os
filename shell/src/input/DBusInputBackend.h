#pragma once

#include "InputBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Input1 (api/dbus/org.ruyaos.Input1.xml) on the system bus, or the session
// bus when RUYA_DBUS=session. The service may start after the shell or restart under it (systemd
// restarts it within 100 ms, 06 §8): every new owner of the name is reported as serviceAppeared.
class DBusInputBackend final : public InputBackend
{
    Q_OBJECT

public:
    explicit DBusInputBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void setRoute(const QString &route, const QString &instance, const QString &appId,
                  const QString &profile) override;

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
