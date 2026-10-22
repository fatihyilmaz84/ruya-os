#pragma once

#include "ProfilesBackend.h"

#include <QDeadlineTimer>
#include <QHash>

// In-memory stand-in for ruya-profiles. Mirrors the service's observable rules (5 free
// attempts, then a 30 s lockout) closely enough for UI work; it is not the security
// implementation. Seeded profiles: p1 "Player One" (admin, PIN 1234), p2 "Ada" (no PIN),
// p3 "Guest".
class MockProfilesBackend final : public ProfilesBackend
{
    Q_OBJECT

public:
    explicit MockProfilesBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void switchTo(const QString &id, const QString &pin) override;
    void lock() override;

private:
    struct Entry
    {
        ProfileInfo info;
        QString pin;
        int failures = 0;
        QDeadlineTimer lockedUntil{QDeadlineTimer::Forever};
    };

    void finish(const QString &id, const QString &status, int attemptsLeft = 0, int retryAfterSecs = 0);

    QList<Entry> m_entries;
    QString m_active;
};
