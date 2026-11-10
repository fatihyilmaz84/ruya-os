#pragma once

#include "PerformanceBackend.h"

#include <QDBusConnection>

// Client of org.ruyaos.Devices1.System.GetPerformance (api/dbus/org.ruyaos.Devices1.xml) on the
// system bus, or the session bus when RUYA_DBUS=session. Asked only by the Performance facade's
// timer, which runs only while a consumer is open; nothing is read at start.
class DBusPerformanceBackend final : public PerformanceBackend
{
    Q_OBJECT
public:
    explicit DBusPerformanceBackend(QObject *parent = nullptr);
    bool isMock() const override { return false; }
    void refresh() override;

private:
    QDBusConnection m_bus;
};
