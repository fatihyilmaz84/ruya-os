#pragma once

#include "ProfilesBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Profiles1. Backend: RUYA_SERVICES=mock|dbus; defaults to D-Bus on
// Linux and the mock elsewhere (Windows development host).
class Profiles : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QVariantList profiles READ profiles NOTIFY profilesChanged)
    Q_PROPERTY(QString activeProfile READ activeProfile NOTIFY activeProfileChanged)
    Q_PROPERTY(QVariantMap active READ active NOTIFY activeProfileChanged)
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Profiles(std::unique_ptr<ProfilesBackend> backend, QObject *parent = nullptr);
    ~Profiles() override;

    static Profiles *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList profiles() const { return m_profiles; }
    QString activeProfile() const { return m_active; }
    QVariantMap active() const;
    bool isAvailable() const { return m_available; }
    bool isMock() const { return m_backend->isMock(); }

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void switchTo(const QString &id, const QString &pin = {});
    Q_INVOKABLE void lock();
    // Admin-gated create (contract: CreateProfile) and PIN change/removal (SetPin; newPin ""
    // removes). Results arrive as createFinished / setPinFinished.
    Q_INVOKABLE void createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                                   const QString &role, const QString &pin);
    Q_INVOKABLE void setPin(const QString &id, const QString &oldPin, const QString &newPin);
    // Tests only, and only with the mock backend (otherwise a no-op that returns false):
    // "seeded" (the three default profiles) or "empty" (first boot).
    Q_INVOKABLE bool resetMockForTests(const QString &state);

signals:
    void profilesChanged();
    void activeProfileChanged();
    void availableChanged();
    // status: see api/dbus/org.ruyaos.Profiles1.xml
    void switchFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);
    // status: see the XML; `id` is the new profile on "ok". attemptsLeft / retryAfterSecs
    // accompany "wrong-pin" / "locked-out" (0 when unknown).
    void createFinished(const QString &status, const QString &id, int attemptsLeft, int retryAfterSecs);
    void setPinFinished(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs);

private:
    std::unique_ptr<ProfilesBackend> m_backend;
    QVariantList m_profiles;
    QString m_active;
    bool m_available = false;
};
