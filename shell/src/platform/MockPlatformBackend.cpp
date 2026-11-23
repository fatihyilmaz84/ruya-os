#include "MockPlatformBackend.h"

#include <QTimer>

#include <algorithm>

MockPlatformBackend::MockPlatformBackend(QObject *parent)
    : PlatformBackend(parent)
{
    reset();
}

void MockPlatformBackend::reset()
{
    m_capabilities = {{QStringLiteral("lifecycle"), true}};
    m_permissions.clear();
}

template<typename F> void MockPlatformBackend::later(F &&reply)
{
    ++m_pending;
    QTimer::singleShot(qMax(0, m_delay), this, [this, reply = std::forward<F>(reply)] {
        --m_pending;
        reply();
    });
}

void MockPlatformBackend::listCapabilities()
{
    const quint64 request = beginCapabilitiesRequest();
    later([this, request, snapshot = m_capabilities] {
        deliverCapabilities(request, QStringLiteral("ok"), snapshot);
    });
}

void MockPlatformBackend::listPermissions(const QString &profileId)
{
    const quint64 request = beginPermissionsRequest();
    if (profileId.isEmpty()) {
        later([this, request, profileId] { deliverPermissions(request, profileId, QStringLiteral("invalid-argument"), {}); });
        return;
    }
    later([this, request, profileId, snapshot = m_permissions.value(profileId)] {
        deliverPermissions(request, profileId, QStringLiteral("ok"), snapshot);
    });
}

void MockPlatformBackend::setPermission(const QString &profileId, const QString &appId, const QString &capability,
                                        bool allowed)
{
    QString status = QStringLiteral("ok");
    const bool known = std::any_of(m_capabilities.cbegin(), m_capabilities.cend(),
                                   [&](const CapabilityInfo &c) { return c.key == capability; });
    if (profileId.isEmpty() || appId.isEmpty() || !known) {
        status = QStringLiteral("invalid-argument");
    } else {
        QList<PermissionInfo> &list = m_permissions[profileId];
        auto it = std::find_if(list.begin(), list.end(), [&](const PermissionInfo &p) {
            return p.appId == appId && p.capability == capability;
        });
        if (it != list.end())
            it->allowed = allowed;
        else
            list.append({appId, capability, allowed});
    }
    // A set is answered at once (next turn); only the lists can be held back.
    QTimer::singleShot(0, this, [this, profileId, appId, capability, status] {
        emit permissionSet(profileId, appId, capability, status);
    });
}
