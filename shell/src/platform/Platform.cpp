#include "Platform.h"
#include "ServicesChoice.h"

#include "DBusPlatformBackend.h"
#include "MockPlatformBackend.h"
#include "Profiles.h"

#include <QTimer>

Platform::Platform(std::unique_ptr<PlatformBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &PlatformBackend::capabilitiesListed, this,
            [this](const QString &status, const QList<CapabilityInfo> &list) {
        if (status != QLatin1String("ok")) {
            emit capabilitiesFailed(status);
            return;
        }
        m_capabilities.clear();
        for (const CapabilityInfo &c : list) {
            m_capabilities.append(QVariantMap{{QStringLiteral("key"), c.key},
                                              {QStringLiteral("defaultAllowed"), c.defaultAllowed}});
        }
        emit capabilitiesChanged();
    });
    connect(m_backend.get(), &PlatformBackend::permissionsListed, this,
            [this](const QString &profileId, const QString &status, const QList<PermissionInfo> &list) {
        if (status != QLatin1String("ok")) {
            emit permissionsFailed(profileId, status);
            return;
        }
        m_permissions.clear();
        for (const PermissionInfo &p : list) {
            m_permissions.append(QVariantMap{{QStringLiteral("appId"), p.appId},
                                             {QStringLiteral("capability"), p.capability},
                                             {QStringLiteral("allowed"), p.allowed}});
        }
        m_permissionsProfile = profileId;
        emit permissionsChanged();
    });
    connect(m_backend.get(), &PlatformBackend::permissionSet, this, &Platform::setPermissionFinished);
}

Platform::~Platform() = default;

Platform *Platform::create(QQmlEngine *qmlEngine, QJSEngine *)
{
    const bool mock = ruya::useMockServices();
    std::unique_ptr<PlatformBackend> backend;
    if (mock)
        backend = std::make_unique<MockPlatformBackend>();
    else
        backend = std::make_unique<DBusPlatformBackend>();
    auto *platform = new Platform(std::move(backend));
    platform->m_engine = qmlEngine;
    return platform;
}

bool Platform::mayChange(const QString &profileId) const
{
    auto *profiles = m_engine ? m_engine->singletonInstance<Profiles *>("RuyaShell", "Profiles") : nullptr;
    if (!profiles || profileId.isEmpty())
        return false;
    // A temporary guest is the active profile (it is not in `profiles`, so `active` is empty) or a
    // guest-role profile is: it has the defaults only. A target that is a temporary guest has them
    // too.
    const QVariantMap active = profiles->active();
    const QString role = active.value(QStringLiteral("role")).toString();
    if (active.isEmpty() || role == QLatin1String("guest"))
        return false;
    for (const QVariant &g : profiles->guests()) {
        if (g.toMap().value(QStringLiteral("id")).toString() == profileId)
            return false;
    }
    return role == QLatin1String("admin") || profileId == profiles->activeProfile();
}

void Platform::refreshCapabilities()
{
    m_backend->listCapabilities();
}

void Platform::refreshPermissions(const QString &profileId)
{
    m_backend->listPermissions(profileId);
}

void Platform::setPermission(const QString &profileId, const QString &appId, const QString &capability, bool allowed)
{
    if (!mayChange(profileId)) {
        QTimer::singleShot(0, this, [this, profileId, appId, capability] {
            emit setPermissionFinished(profileId, appId, capability, QStringLiteral("not-allowed"));
        });
        return;
    }
    m_backend->setPermission(profileId, appId, capability, allowed);
}

void Platform::mockReset()
{
    if (auto *mock = qobject_cast<MockPlatformBackend *>(m_backend.get()))
        mock->reset();
}

void Platform::mockRefreshDelayed(int ms, const QString &profileId)
{
    if (auto *mock = qobject_cast<MockPlatformBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        mock->listPermissions(profileId);
        mock->setReplyDelay(0);
    }
}

int Platform::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockPlatformBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
