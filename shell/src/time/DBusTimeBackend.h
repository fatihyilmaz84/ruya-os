#pragma once

#include "TimeBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>
#include <QVariantMap>

// Client of org.ruyaos.Devices1.Time (api/dbus/org.ruyaos.Devices1.xml) on the system bus, or the
// session bus when RUYA_DBUS=session. The service may start after the shell, so the state is read
// again whenever the name appears. Unverified: only a VM run of ruya-devices proves it.
class DBusTimeBackend final : public TimeBackend
{
    Q_OBJECT

public:
    explicit DBusTimeBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void loadZones() override;
    void setTimezone(const QString &name) override;

private slots:
    void onChanged() { refresh(); }
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
