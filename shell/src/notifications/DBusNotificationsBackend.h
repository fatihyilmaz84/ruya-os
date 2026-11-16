#pragma once

#include "NotificationsBackend.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusServiceWatcher>

// Client of org.ruyaos.Notifications1 (api/dbus/org.ruyaos.Notifications1.xml), served by
// ruya-notifications (RUY-730), on the system bus, or the session bus when RUYA_DBUS=session. The
// service may start after the shell or restart, so the settings are read again whenever the name
// appears and `changed("")` makes the facade list again. While the name has no owner nothing is
// called: the toasts still show and nothing is kept, and the journal says so once when the name is
// missing at start and once each time it goes away ("Notifications1 is not on the bus; ...").
// No host test reaches this class (no bus on Windows, the tests run the mock); the VM check
// scripts/vm-notifications-check.sh covers the log line and the re-read after a restart.
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
    // Logs once that the service is missing (reset when it comes back).
    void tellAbsent();

    bool m_up = false;
    bool m_known = false;        // NameHasOwner has answered (before, a missing owner is not logged)
    bool m_toldAbsent = false;

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
};
