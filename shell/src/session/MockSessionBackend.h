#pragma once

#include "SessionBackend.h"

#include <functional>

// In-memory sessions. An app id "org.example.*" is installed; "crashy" is too and exits with
// reason "crashed" shortly after it runs. Launch goes starting -> running after about 300 ms
// (10 ms with RUYA_MOCK_FAST=1); Stop exits with reason "quit" after about a third of that.
// One app id runs once per profile. The profile check is injected (the Session facade passes
// the mock Profiles list); without one every profile is known.
class MockSessionBackend final : public SessionBackend
{
    Q_OBJECT

public:
    using ProfileCheck = std::function<bool(const QString &)>;
    explicit MockSessionBackend(ProfileCheck knownProfile = {}, QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void launch(const QString &appId, const QString &profile) override;
    void stop(const QString &instance) override;

    void reset();

private:
    int indexOf(const QString &instance) const;
    void setRunning(const QString &instance);
    void exitApp(const QString &instance, int code, const QString &reason);

    ProfileCheck m_knownProfile;
    QList<RunningApp> m_running;
    int m_next = 1;
    int m_startMs = 300;
};
