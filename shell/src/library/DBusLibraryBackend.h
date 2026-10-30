#pragma once

#include "LibraryBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Library1 (api/dbus/org.ruyaos.Library1.xml) on the system bus, or the
// session bus when RUYA_DBUS=session. The service may start after the shell, so the list is read
// again whenever the name appears.
class DBusLibraryBackend final : public LibraryBackend
{
    Q_OBJECT

public:
    explicit DBusLibraryBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void listItems() override;
    void rescan() override;

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
