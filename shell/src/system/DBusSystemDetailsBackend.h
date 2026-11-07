#pragma once

#include "SystemDetailsBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Devices1.System (api/dbus/org.ruyaos.Devices1.xml) on the system bus, or the
// session bus when RUYA_DBUS=session. The service may start after the shell, so the dictionary is
// read again whenever the name appears; SystemInfoChanged (a key that is not live differs) means
// "read again". The live keys are read by the page's own timer while it is visible.
class DBusSystemDetailsBackend final : public SystemDetailsBackend
{
    Q_OBJECT

public:
    explicit DBusSystemDetailsBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;

private slots:
    void onChanged() { refresh(); }

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
