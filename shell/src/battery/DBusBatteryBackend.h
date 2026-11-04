#pragma once

#include "BatteryBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Devices1.Batteries (api/dbus/org.ruyaos.Devices1.xml) on the system bus,
// or the session bus when RUYA_DBUS=session. The service may start after the shell, so the
// list is read again whenever the name appears.
class DBusBatteryBackend final : public BatteryBackend
{
    Q_OBJECT

public:
    explicit DBusBatteryBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;

private slots:
    void onBatteriesChanged() { refresh(); }

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
