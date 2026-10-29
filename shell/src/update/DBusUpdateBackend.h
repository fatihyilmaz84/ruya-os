#pragma once

#include "UpdateBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Update1 (api/dbus/org.ruyaos.Update1.xml) on the system bus, or the
// session bus when RUYA_DBUS=session. The service may start after the shell, so the status is
// read again whenever the name appears. Unverified: ruya-update does not exist yet.
class DBusUpdateBackend final : public UpdateBackend
{
    Q_OBJECT

public:
    explicit DBusUpdateBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void check() override;
    void download() override;
    void rollback() override;
    void setChannel(const QString &channel) override;

private slots:
    void onStatusChanged();

private:
    // Check, Download and Rollback take no argument and answer (status).
    void call(const QString &method, const QString &reportAs, const QVariantList &args = {});

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
