#pragma once

#include "NotificationsBackend.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Notifications1 (api/dbus/org.ruyaos.Notifications1.xml) on the system bus,
// or the session bus when RUYA_DBUS=session. The service (RUY-88) may start after the shell, so
// the settings are read again whenever the name appears and `changed("")` makes the facade list again.
// While the name has no owner (the image has no Notifications1 until RUY-88) nothing is called:
// one log line says so, the toasts still show and nothing is kept.
// Unverified until RUY-88 builds the service: compiled on Windows, run only against the mock.
class DBusNotificationsBackend final : public NotificationsBackend
{
    Q_OBJECT

public:
    explicit DBusNotificationsBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh(const QString &profile) override;
    void refreshSettings() override;
    void selectProfile(const QString &profile) override;
    void dismiss(uint id) override;
    void dismissAll(const QString &profile) override;
    void invoke(uint id, const QString &action) override;
    void markRead(const QString &profile) override;
    void post(const QString &profile, const QString &key, const NotificationItem &item) override;
    void withdraw(const QString &key) override;
    void setSetting(const QString &name, const QVariant &value) override;

private slots:
    void onAdded(const QDBusMessage &message);
    void onRemoved(const QDBusMessage &message);
    void onChanged(const QString &profile);
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    // A method that answers one status string.
    void call(const QString &method, const QString &op, uint id, const QVariantList &args);
    // The service has an owner on the bus; logs once when it has none.
    bool available();
    void serviceUp();

    bool m_up = false;
    bool m_known = false;        // NameHasOwner has answered (before, a missing owner is not logged)
    bool m_toldAbsent = false;

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
