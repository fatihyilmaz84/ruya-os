#pragma once

#include "StorageBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Devices1.Storage (api/dbus/org.ruyaos.Devices1.xml) on the system bus,
// or the session bus when RUYA_DBUS=session. The service may start after the shell, so the
// list is read again whenever the name appears. Unverified: no service exists yet.
class DBusStorageBackend final : public StorageBackend
{
    Q_OBJECT

public:
    explicit DBusStorageBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void eject(const QString &id) override;

private slots:
    void onVolumesChanged();
    void onVolumeAdded(const QString &id);

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
