#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>

// One capability of org.ruyaos.Platform1 and what it is before the player chose (ListCapabilities).
struct CapabilityInfo
{
    QString key;
    bool defaultAllowed = false;
};

// One choice the player made (ListPermissions): `capability` of `appId` is `allowed`.
struct PermissionInfo
{
    QString appId;
    QString capability;
    bool allowed = false;
};

// Transport behind the Platform QML singleton: org.ruyaos.Platform1.Manage over D-Bus
// (api/dbus/org.ruyaos.Platform1.xml), or an in-memory mock. Results arrive asynchronously through
// signals, so QML code behaves the same with either. Status strings: see the XML.
class PlatformBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void listCapabilities() = 0;
    virtual void listPermissions(const QString &profileId) = 0;
    virtual void setPermission(const QString &profileId, const QString &appId, const QString &capability,
                               bool allowed) = 0;

signals:
    void capabilitiesListed(const QString &status, const QList<CapabilityInfo> &capabilities);
    void permissionsListed(const QString &profileId, const QString &status, const QList<PermissionInfo> &permissions);
    void permissionSet(const QString &profileId, const QString &appId, const QString &capability,
                       const QString &status);

protected:
    // Replies can arrive out of order: number each list request when it is sent and report only
    // the newest outcome so far (RequestSequence.h; a failure counts). The permission list is one
    // sequence for every profile: the pane shows one profile at a time, so asking for another
    // profile's list makes the older reply stale.
    quint64 beginCapabilitiesRequest() { return m_capabilitiesSeq.begin(); }
    void deliverCapabilities(quint64 request, const QString &status, const QList<CapabilityInfo> &capabilities)
    {
        if (m_capabilitiesSeq.accept(request))
            emit capabilitiesListed(status, capabilities);
    }
    quint64 beginPermissionsRequest() { return m_permissionsSeq.begin(); }
    void deliverPermissions(quint64 request, const QString &profileId, const QString &status,
                            const QList<PermissionInfo> &permissions)
    {
        if (m_permissionsSeq.accept(request))
            emit permissionsListed(profileId, status, permissions);
    }

private:
    RequestSequence m_capabilitiesSeq;
    RequestSequence m_permissionsSeq;
};
