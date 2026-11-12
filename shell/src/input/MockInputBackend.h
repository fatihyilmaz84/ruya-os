#pragma once

#include "InputBackend.h"

#include <QVariantList>

// In-memory stand-in for ruya-inputd's routing (RUY-409). It checks SetRoute's arguments by the
// service's rules (services/ruya-inputd/src/routing.rs: the shape of each route and the app id's
// form; any non-empty profile is taken), keeps the route and models the virtual pads: they exist
// only for "app" and stay for "overlay" with the same instance and profile; anything else destroys
// them (06 §5.1). Answers arrive asynchronously, like D-Bus replies. Every call is logged for tests.
class MockInputBackend final : public InputBackend
{
    Q_OBJECT

public:
    explicit MockInputBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void setRoute(const QString &route, const QString &instance, const QString &appId,
                  const QString &profile) override;

    // Tests: every SetRoute as { route, instance, appId, profile }, oldest first.
    QVariantList calls() const { return m_calls; }
    void clearCalls() { m_calls.clear(); }
    QString route() const { return m_route; }
    QString instance() const { return m_instance; }
    QString profile() const { return m_profile; }
    bool pads() const { return m_pads; }
    // How many times virtual pads were made (a new owner, or back after they were destroyed).
    int padGeneration() const { return m_padGeneration; }
    // While true every call fails as if the service were gone (nothing changes, "failed").
    void setFail(bool fail) { m_fail = fail; }
    // The service restarts: the route is "shell" with no profile and no pads, then the name has
    // a new owner (serviceAppeared, asynchronously).
    void restart();

private:
    QVariantList m_calls;
    QString m_route = QStringLiteral("shell");
    QString m_instance;
    QString m_profile;
    bool m_pads = false;
    int m_padGeneration = 0;
    bool m_fail = false;
};
