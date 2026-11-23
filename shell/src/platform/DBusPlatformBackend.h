#pragma once

#include "PlatformBackend.h"

#include <QDBusConnection>

// Client of org.ruyaos.Platform1.Manage (api/dbus/org.ruyaos.Platform1.xml) on the system bus, or
// the session bus when RUYA_DBUS=session. The service has no change signal: the facade asks again
// when it needs the lists.
class DBusPlatformBackend final : public PlatformBackend
{
    Q_OBJECT

public:
    explicit DBusPlatformBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void listCapabilities() override;
    void listPermissions(const QString &profileId) override;
    void setPermission(const QString &profileId, const QString &appId, const QString &capability,
                       bool allowed) override;

private:
    QDBusConnection m_bus;
};
