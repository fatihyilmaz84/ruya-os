#pragma once

#include "TimeBackend.h"

// In-memory Devices1.Time: a console that has not been set up (zone "UTC", clock synchronised) and
// a list of about seventy zones in every region. SetTimezone follows the service's rules: a name
// that is not in the list is "invalid", "forbidden" while the caller is not allowed (test hook;
// the real rule is an admin profile, or no profile yet during setup).
class MockTimeBackend final : public TimeBackend
{
    Q_OBJECT

public:
    explicit MockTimeBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void loadZones() override;
    void setTimezone(const QString &name) override;

    // Test hooks (reached through Time.mock*).
    void reset();
    // Someone else (timedatectl) changed the zone: the state is published.
    void setOutside(const QString &name);
    void setNtp(bool synchronised);
    void setCallerAllowed(bool allowed) { m_callerAllowed = allowed; }
    // The next SetTimezone fails ("failed").
    void setFailNext(bool fail) { m_failNext = fail; }
    int setCalls() const { return m_setCalls; }
    // Replies to refresh() arrive after `ms` with the state as it was when asked; the number of
    // replies still on their way (a test plays an old reply landing after a new one).
    void refreshDelayed(int ms);
    int pendingReplies() const { return m_pending; }

private:
    void publish();

    QString m_timezone;
    bool m_ntp = true;
    bool m_callerAllowed = true;
    bool m_failNext = false;
    int m_setCalls = 0;
    int m_pending = 0;
    QStringList m_zones;
};
