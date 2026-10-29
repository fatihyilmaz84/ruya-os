#pragma once

#include "ProfilesBackend.h"

#include <QDBusConnection>

// Client of org.ruyaos.Profiles1 (api/dbus/org.ruyaos.Profiles1.xml) on the system bus,
// or the session bus when RUYA_DBUS=session (for running ruya-profiles --session in dev).
class DBusProfilesBackend final : public ProfilesBackend
{
    Q_OBJECT

public:
    explicit DBusProfilesBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh() override;
    void switchTo(const QString &id, const QString &pin) override;
    void lock() override;
    void createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                       const QString &role, const QString &pin) override;
    void setPin(const QString &id, const QString &oldPin, const QString &newPin) override;
    void renameProfile(const QString &actorId, const QString &actorPin, const QString &id,
                       const QString &name) override;
    void deleteProfile(const QString &adminId, const QString &adminPin, const QString &id) override;
    void verifyAdmin(const QString &adminId, const QString &adminPin) override;

private slots:
    void onProfilesChanged();
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    void fetchActive();

    QDBusConnection m_bus;
};
