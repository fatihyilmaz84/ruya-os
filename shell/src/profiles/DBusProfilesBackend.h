#pragma once

#include "ProfilesBackend.h"

#include <QDBusConnection>

#include <functional>

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

private slots:
    void onProfilesChanged();
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    void fetchActive();
    // The CreateProfile/SetPin replies carry no attempt counts. After a "wrong-pin" or
    // "locked-out" status, ask SwitchTo(id, "") (side-effect free for a PIN-protected
    // profile: "pin-required" + attempts_left, or "locked-out" + retry_after) and hand the
    // numbers to `done`. If the probe fails, done gets zeros.
    void probeAttempts(const QString &id, std::function<void(int attemptsLeft, int retryAfterSecs)> done);

    QDBusConnection m_bus;
};
