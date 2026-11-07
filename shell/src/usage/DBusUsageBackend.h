#pragma once

#include "UsageBackend.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>

// Client of the play ledger in org.ruyaos.Session1 (api/dbus/org.ruyaos.Session1.xml: ReportPresence,
// ListSessions, GetTotals, ClearHistory, UsageChanged) on the system bus, or the session bus when
// RUYA_DBUS=session. Compiles on every host; it can only run against ruya-session on Linux
// (unverified here, checked by scripts/vm-usage-check.sh).
class DBusUsageBackend final : public UsageBackend
{
    Q_OBJECT

public:
    explicit DBusUsageBackend(QObject *parent = nullptr);

    bool isMock() const override { return false; }
    void refresh(const QString &profile) override;
    void clearHistory(const QString &profile) override;
    void reportPresence(const QString &profile, const QString &instance, const QString &attention) override;

private:
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
    bool m_presenceWarned = false;
    QString m_lastProfile;
};
