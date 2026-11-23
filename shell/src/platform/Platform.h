#pragma once

#include "PlatformBackend.h"

#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Platform1.Manage (ADR-022): which capabilities exist, and what each
// profile allowed each app. Backend: RUYA_SERVICES=mock|dbus; D-Bus on Linux, the mock elsewhere.
// The service cannot tell people apart (its Manage callers are root and this shell), so who may
// change whose permissions is decided here, in mayChange() (03 §4.4).
class Platform : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // Every capability and its default, as the last ListCapabilities said: {key, defaultAllowed}.
    Q_PROPERTY(QVariantList capabilities READ capabilities NOTIFY capabilitiesChanged)
    // The choices of `permissionsProfile`, as the last ListPermissions said: {appId, capability,
    // allowed}. A pair that is not listed has its capability's default.
    Q_PROPERTY(QVariantList permissions READ permissions NOTIFY permissionsChanged)
    Q_PROPERTY(QString permissionsProfile READ permissionsProfile NOTIFY permissionsChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Platform(std::unique_ptr<PlatformBackend> backend, QObject *parent = nullptr);
    ~Platform() override;

    static Platform *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList capabilities() const { return m_capabilities; }
    QVariantList permissions() const { return m_permissions; }
    QString permissionsProfile() const { return m_permissionsProfile; }
    bool isMock() const { return m_backend->isMock(); }

    // The one rule of who changes what (lead-45, ADR-022): a profile changes its own permissions,
    // an admin any profile's, a guest nobody's and nobody changes a guest's (its choices would die
    // with it: it has the defaults only).
    Q_INVOKABLE bool mayChange(const QString &profileId) const;

    Q_INVOKABLE void refreshCapabilities();
    // The result arrives as `permissions` / `permissionsProfile`, or as permissionsFailed.
    Q_INVOKABLE void refreshPermissions(const QString &profileId);
    // Refused at once with "not-allowed" when the active profile may not change `profileId`'s
    // (mayChange); the result arrives as setPermissionFinished.
    Q_INVOKABLE void setPermission(const QString &profileId, const QString &appId, const QString &capability,
                                   bool allowed);

    // Tests only, and only with the mock backend (otherwise no-ops).
    Q_INVOKABLE void mockReset();
    // Asks for `profileId`'s list; the reply arrives after `ms` and shows the data as it is now.
    Q_INVOKABLE void mockRefreshDelayed(int ms, const QString &profileId);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void capabilitiesChanged();
    void permissionsChanged();
    // status: see api/dbus/org.ruyaos.Platform1.xml
    void capabilitiesFailed(const QString &status);
    void permissionsFailed(const QString &profileId, const QString &status);
    // status: as the XML; "not-allowed" also when mayChange said no.
    void setPermissionFinished(const QString &profileId, const QString &appId, const QString &capability,
                               const QString &status);

private:
    std::unique_ptr<PlatformBackend> m_backend;
    QPointer<QQmlEngine> m_engine; // where the Profiles singleton is found (set by create())
    QVariantList m_capabilities;
    QVariantList m_permissions;
    QString m_permissionsProfile;
};
