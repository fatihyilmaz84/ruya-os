#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>

struct ProfileInfo
{
    QString id;
    QString name;
    QString avatar; // "#rrggbb"
    QString role;   // "admin" | "standard" | "guest"
    bool hasPin = false;
};

// Transport behind the Profiles QML singleton: the real org.ruyaos.Profiles1 service over
// D-Bus, or an in-memory mock for development hosts and tests. All results arrive
// asynchronously through signals, so QML code behaves the same with either.
class ProfilesBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;
    virtual void switchTo(const QString &id, const QString &pin) = 0;
    virtual void lock() = 0;
    // Mirror CreateProfile / SetPin of the contract (status strings: see the XML).
    virtual void createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                               const QString &role, const QString &pin) = 0;
    virtual void setPin(const QString &id, const QString &oldPin, const QString &newPin) = 0;
    // Mirror RenameProfile / DeleteProfile of the contract.
    virtual void renameProfile(const QString &actorId, const QString &actorPin, const QString &id,
                               const QString &name) = 0;
    virtual void deleteProfile(const QString &adminId, const QString &adminPin, const QString &id) = 0;
    // Mirrors VerifyAdmin: checks the admin's PIN and changes nothing.
    virtual void verifyAdmin(const QString &adminId, const QString &adminPin) = 0;

signals:
    void listed(const QList<ProfileInfo> &profiles);
    void activeChanged(const QString &id);
    void switchFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    // `id` is the new profile's id on "ok". attemptsLeft / retryAfterSecs come from the reply
    // and matter for "wrong-pin" / "locked-out" (0 otherwise), like switchFinished.
    void createFinished(const QString &status, const QString &id, int attemptsLeft, int retryAfterSecs);
    void setPinFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    // `id` is the profile that was renamed / deleted; the rest is shaped like setPinFinished.
    void renameFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    void deleteFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    void verifyAdminFinished(const QString &adminId, const QString &status, int attemptsLeft, int retryAfterSecs);
    void availabilityChanged(bool available);

protected:
    // Replies can arrive out of order (and a ProfilesChanged can cross a reply): number each list
    // request when it is sent; only the newest outcome so far is reported (RequestSequence.h,
    // T-181, T-191). The availability follows the same outcome as the list.
    quint64 beginListRequest() { return m_listSeq.begin(); }
    // True when this outcome is the newest so far (a failure counts, so an older success that
    // arrives after a newer failure is dropped).
    bool acceptList(quint64 request) { return m_listSeq.accept(request); }
    void deliverList(quint64 request, const QList<ProfileInfo> &profiles)
    {
        if (acceptList(request))
            emit listed(profiles);
    }

private:
    RequestSequence m_listSeq;
};
