#pragma once

#include "ThermalBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Devices1.Thermal (api/dbus/org.ruyaos.Devices1.xml) on the system bus,
// or the session bus when RUYA_DBUS=session. The service may start after the shell, so the
// list is read again whenever the name appears. SensorsChanged and LevelChanged both mean
// "read the list again": the level is derived from the list (the service's Level property is for
// other clients).
class DBusThermalBackend final : public ThermalBackend
{
    Q_OBJECT

public:
    explicit DBusThermalBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;

private slots:
    void onChanged() { refresh(); }

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
