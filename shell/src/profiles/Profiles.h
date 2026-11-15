#pragma once

#include "ProfilesBackend.h"

#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QSet>
#include <QVariantList>

#include <memory>

class Input;

// QML face of org.ruyaos.Profiles1. Backend: RUYA_SERVICES=mock|dbus; defaults to D-Bus on
// Linux and the mock elsewhere (Windows development host).
class Profiles : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QVariantList profiles READ profiles NOTIFY profilesChanged)
    // The live temporary guests (RUY-125), by number: {id, avatar, number}. Never in `profiles`.
    Q_PROPERTY(QVariantList guests READ guests NOTIFY guestsChanged)
    Q_PROPERTY(QString activeProfile READ activeProfile NOTIFY activeProfileChanged)
    Q_PROPERTY(QVariantMap active READ active NOTIFY activeProfileChanged)
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Profiles(std::unique_ptr<ProfilesBackend> backend, QObject *parent = nullptr);
    ~Profiles() override;

    static Profiles *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList profiles() const { return m_profiles; }
    QVariantList guests() const { return m_guests; }
    QString activeProfile() const { return m_active; }
    QVariantMap active() const;
    bool isAvailable() const { return m_available; }
    bool isMock() const { return m_backend->isMock(); }

    // A profile's name by id; for a temporary guest "Guest" (number 1) or "Guest n", translated
    // (RUY-631; a binding on the name itself, like PlayerChip's, uses qsTr to follow a language
    // change); empty for an unknown id.
    Q_INVOKABLE QString nameOf(const QString &id) const;
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void switchTo(const QString &id, const QString &pin = {});
    Q_INVOKABLE void lock();
    // Admin-gated create (contract: CreateProfile) and PIN change/removal (SetPin; newPin ""
    // removes). Results arrive as createFinished / setPinFinished.
    Q_INVOKABLE void createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                                   const QString &role, const QString &pin);
    Q_INVOKABLE void setPin(const QString &id, const QString &oldPin, const QString &newPin);
    // Contract: RenameProfile (admin or the profile itself) and DeleteProfile (admin only).
    // Results arrive as renameFinished / deleteFinished.
    Q_INVOKABLE void renameProfile(const QString &actorId, const QString &actorPin, const QString &id,
                                   const QString &name);
    Q_INVOKABLE void deleteProfile(const QString &adminId, const QString &adminPin, const QString &id);
    // Contract: VerifyAdmin. For actions of other services behind an admin PIN (a system
    // rollback). The result arrives as verifyAdminFinished.
    Q_INVOKABLE void verifyAdmin(const QString &adminId, const QString &adminPin);
    // Contract: VerifyPin. Checks a profile's PIN for a player who joins; the active profile
    // stays. The result arrives as pinVerified.
    Q_INVOKABLE void verifyPin(const QString &id, const QString &pin = {});
    // Contract: CreateGuest / RemoveGuest. A temporary guest for the signed-in session; the
    // results arrive as guestCreated / guestRemoved, the list as `guests`.
    Q_INVOKABLE void createGuest();
    Q_INVOKABLE void removeGuest(const QString &id);
    // Tests only, and only with the mock backend (otherwise a no-op that returns false):
    // "seeded" (the three default profiles) or "empty" (first boot).
    Q_INVOKABLE bool resetMockForTests(const QString &state);
    // A list request whose reply (a snapshot of now) arrives after ms, and how many replies are
    // still due. No-ops with the D-Bus backend.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;
    // The service is (not) there, as availableChanged says it (the "Who's playing?" waiting text,
    // RUY-122). A no-op with the D-Bus backend.
    Q_INVOKABLE void mockSetAvailable(bool available);
    // Tests only (mock): the next `times` CreateGuest or RemoveGuest calls (`method` "createGuest" /
    // "removeGuest") answer `status` and change nothing; "listGuests": the next `times` ListGuests
    // fail (no guestsListed, as over D-Bus).
    Q_INVOKABLE void mockFailGuests(const QString &method, const QString &status, int times);

signals:
    void profilesChanged();
    void guestsChanged();
    void activeProfileChanged();
    void availableChanged();
    // status: see api/dbus/org.ruyaos.Profiles1.xml
    void switchFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    // status: see the XML; `id` is the new profile on "ok". attemptsLeft / retryAfterSecs
    // accompany "wrong-pin" / "locked-out" (0 when unknown).
    void createFinished(const QString &status, const QString &id, int attemptsLeft, int retryAfterSecs);
    void setPinFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    void renameFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    void deleteFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    void verifyAdminFinished(const QString &adminId, const QString &status, int attemptsLeft, int retryAfterSecs);
    void pinVerified(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    // status: "ok", "not-allowed", "full", "failed"; id and number are set on "ok".
    void guestCreated(const QString &status, const QString &id, int number);
    // status: "ok", "unknown-profile", "failed".
    void guestRemoved(const QString &id, const QString &status);

private:
    // RUY-468 (06 §7 "Storage"): a console profile that goes takes its controller profiles in
    // ruya-inputd with it: after DeleteProfile answers "ok", for every guest that leaves `guests`,
    // and at start for every id Input1 still stores that is neither a profile nor a live guest, once
    // both lists have answered "ok" (never on a partial view).
    Input *input() const;
    void forgetInputOf(const QString &id);
    void sweepWhenListed();
    void finishSweep(const QString &status, const QStringList &stored);
    QSet<QString> listedIds() const;
    enum class Sweep { Waiting, Asked, Done };

    std::unique_ptr<ProfilesBackend> m_backend;
    QVariantList m_profiles;
    QVariantList m_guests;
    QString m_active;
    bool m_available = false;
    QPointer<QQmlEngine> m_engine;   // where the Input singleton is found (set by create())
    bool m_profilesListed = false;   // ListProfiles answered "ok" once
    bool m_guestsListed = false;     // ListGuests answered "ok" once
    Sweep m_sweep = Sweep::Waiting;
    QSet<QString> m_sweepKeep;       // every id listed since the sweep asked Input1
};
