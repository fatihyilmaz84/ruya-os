#pragma once

#include "ProfilesBackend.h"

#include <QDeadlineTimer>
#include <QHash>

// In-memory stand-in for ruya-profiles. Mirrors the rules of services/ruya-profiles
// (service.rs, lockout.rs): PIN format, name and role validation, the admin check for
// CreateProfile, PIN rules for SetPin, and one lockout counter shared by every PIN check
// (5 free attempts, then 30 s doubling up to an hour). It is not the security
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
    void createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                       const QString &role, const QString &pin) override;
    void setPin(const QString &id, const QString &oldPin, const QString &newPin) override;

    // Tests: back to the seeded profiles, or to an empty store (first boot); clears
    // lockouts and the active profile.
    void resetForTests(bool empty);

private:
    struct Entry
    {
        ProfileInfo info;
        QString pin;
        int failures = 0;
        QDeadlineTimer lockedUntil{QDeadlineTimer::Forever};
    };

    struct Outcome
    {
        QString status;
        int attemptsLeft = 0;
        int retryAfterSecs = 0;
    };

    void seed();
    Entry *find(const QString &id);
    // The single place PINs are checked; every failure counts towards lockout.
    Outcome authenticate(const QString &id, const QString &pin);
    void publishList();
    void finish(const QString &id, const QString &status, int attemptsLeft = 0, int retryAfterSecs = 0);

    QList<Entry> m_entries;
    QString m_active;
    int m_nextId = 1; // ids are never reused
};
