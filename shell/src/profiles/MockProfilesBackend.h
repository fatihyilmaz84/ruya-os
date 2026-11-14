#pragma once

#include "ProfilesBackend.h"

#include <QDeadlineTimer>
#include <QHash>

// In-memory stand-in for ruya-profiles. Mirrors the rules of services/ruya-profiles
// (service.rs, lockout.rs): PIN format, name and role validation, the admin check for
// CreateProfile, PIN rules for SetPin, and one lockout counter shared by every PIN check
// (5 free attempts, then 30 s doubling up to an hour). It is not the security
// implementation. Seeded profiles: p1 "Player One" (admin, PIN 1234), p2 "Ada" (no PIN),
// p3 "Guest". Temporary guests (RUY-125) follow the service too: only while a profile is signed
// in, at most 3, numbered lowest free, never in the profile list, wiped on lock() and on a
// switch to another profile. There are no Unix users, so no uids.
class MockProfilesBackend final : public ProfilesBackend
{
    Q_OBJECT

public:
    explicit MockProfilesBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    // Tests only: ask for the list, but deliver the reply (a snapshot of now) after ms.
    void refreshDelayed(int ms);
    int pendingReplies() const { return m_pending; }
    void switchTo(const QString &id, const QString &pin) override;
    void lock() override;
    void createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                       const QString &role, const QString &pin) override;
    void setPin(const QString &id, const QString &oldPin, const QString &newPin) override;
    void renameProfile(const QString &actorId, const QString &actorPin, const QString &id,
                       const QString &name) override;
    void deleteProfile(const QString &adminId, const QString &adminPin, const QString &id) override;
    void verifyAdmin(const QString &adminId, const QString &adminPin) override;
    void verifyPin(const QString &id, const QString &pin) override;
    void createGuest() override;
    void removeGuest(const QString &id) override;

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
    void refreshAfter(int ms);
    Entry *find(const QString &id);
    // The single place PINs are checked; every failure counts towards lockout.
    Outcome authenticate(const QString &id, const QString &pin);
    void publishList();
    void publishGuests();
    bool isGuest(const QString &id) const;
    // Session end (lock, a switch to another profile): every temporary guest goes.
    void wipeGuests();
    void finish(const QString &id, const QString &status, int attemptsLeft = 0, int retryAfterSecs = 0);

    QList<Entry> m_entries;
    QList<GuestInfo> m_guests; // temporary guests, never in m_entries
    QString m_active;
    int m_nextId = 1; // ids are never reused
    int m_pending = 0; // list replies not delivered yet
};
