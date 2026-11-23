#pragma once

#include "PlatformBackend.h"

#include <QHash>

// In-memory Platform1.Manage as the service serves it: one capability, "lifecycle", on by default;
// choices kept per profile. Answers asynchronously, like D-Bus.
class MockPlatformBackend final : public PlatformBackend
{
    Q_OBJECT

public:
    explicit MockPlatformBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void listCapabilities() override;
    void listPermissions(const QString &profileId) override;
    void setPermission(const QString &profileId, const QString &appId, const QString &capability,
                       bool allowed) override;

    // Tests only. Replies to the list calls arrive after `ms` (0: next event loop turn), with the
    // data as it was when asked; the number of replies still on their way. Lets a test play an old
    // reply landing after a newer one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }
    void reset();

private:
    template<typename F> void later(F &&reply);

    QList<CapabilityInfo> m_capabilities;
    QHash<QString, QList<PermissionInfo>> m_permissions; // by profile id
    int m_delay = 0;
    int m_pending = 0;
};
