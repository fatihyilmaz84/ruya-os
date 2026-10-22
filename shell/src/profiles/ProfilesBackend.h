#pragma once

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

signals:
    void listed(const QList<ProfileInfo> &profiles);
    void activeChanged(const QString &id);
    void switchFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    // `id` is the new profile's id on "ok". The contract's replies carry no attempt counts;
    // after "wrong-pin" or "locked-out" the backend fills attemptsLeft / retryAfterSecs in
    // (the mock knows them; the D-Bus backend probes SwitchTo with an empty PIN). 0 = unknown.
    void createFinished(const QString &status, const QString &id, int attemptsLeft, int retryAfterSecs);
    void setPinFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    void availabilityChanged(bool available);
};
