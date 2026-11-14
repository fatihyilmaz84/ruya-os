#pragma once

#include "InputBackend.h"
#include "MockInputProfiles.h"

#include <QHash>
#include <QSet>
#include <QVariantList>
#include <QVariantMap>

// In-memory stand-in for ruya-inputd's routing (RUY-409). It checks SetRoute's arguments by the
// service's rules (services/ruya-inputd/src/routing.rs: the shape of each route and the app id's
// form; any non-empty profile is taken), keeps the route and models the virtual pads: they exist
// only for "app" and stay for "overlay" with the same instance and profile; anything else destroys
// them (06 §5.1). Answers arrive asynchronously, like D-Bus replies. Every call is logged for tests.
// Devices (RUY-39): three pads (a DualSense over Bluetooth, an Xbox pad over USB, a Pro Controller
// over Bluetooth whose motion node does not open), each with the descriptor ruya-inputd's rules
// (caps.rs) give that model; the button test follows the service: only in the route "shell", one
// per device, ended by StopTest, a route other than "shell" or the pad going.
class MockInputBackend final : public InputBackend
{
    Q_OBJECT

public:
    explicit MockInputBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void setRoute(const QString &route, const QString &instance, const QString &appId,
                  const QString &profile) override;
    void refreshDevices() override;
    void getCapabilities(const QString &deviceId) override;
    void startTest(const QString &deviceId, bool holdLeftStick) override;
    void stopTest(const QString &deviceId) override;
    // The controller profiles (RUY-42): MockInputProfiles answers, asynchronously, and a change is
    // one ProfilesChanged after the reply.
    void callProfile(quint64 token, const QString &method, const QVariantMap &args) override;
    // The Confirm button per console profile (RUY-40); the property is the route's profile's.
    void readConfirmButton() override;
    // Tests: the press of a pad is announced (ActiveInputChanged).
    void sendActiveInput(const QString &deviceId, const QString &family)
    {
        emit activeInputChanged(deviceId, family);
    }
    // Tests: the mode stored for a console profile ("family" when none).
    QString confirmButtonOf(const QString &profile) const { return m_confirm.value(profile, QStringLiteral("family")); }
    // Tests: every profile call as { method, args }, oldest first; the profiles back to the
    // built-ins only.
    QVariantList profileCalls() const { return m_profileCalls; }
    void clearProfileCalls() { m_profileCalls.clear(); }
    void resetProfiles()
    {
        m_profiles.reset();
        m_forcedStatus.clear();
        m_forcedOnce.clear();
        m_holdSaves = false;
        m_held.clear();
        m_confirm.clear();
    }
    // While set, every call of `method` answers `status` (its other out-arguments empty) without
    // reaching the profiles: a refused or failed save for the pages' tests (RUY-465). "" clears it.
    void setProfileStatus(const QString &method, const QString &status)
    {
        m_forcedOnce.remove(method);
        if (status.isEmpty())
            m_forcedStatus.remove(method);
        else
            m_forcedStatus.insert(method, status);
    }

    // While on, SaveProfile calls are recorded but not carried out nor answered until the hold ends;
    // then they run in order (RUY-595: a save still in flight).
    void holdSaves(bool hold);

    // Like setProfileStatus, but only the next call of `method` is answered so (RUY-571).
    void setProfileStatusOnce(const QString &method, const QString &status)
    {
        setProfileStatus(method, status);
        if (!status.isEmpty())
            m_forcedOnce.insert(method);
    }

    // Tests (RUY-39). A pad connects (a device record; `capabilities` a list of
    // { name, hardware, driver, available, output }, else none) or changes (same id), or goes.
    void addDevice(const QVariantMap &device);
    void removeDevice(const QString &id);
    // While true ListDevices and GetCapabilities fail ("failed"), as with no service.
    void setListFail(bool fail) { m_listFail = fail; }
    // The pad sends an input: TestInput, only while a test runs for it (as the service does).
    void sendTestInput(const QString &id, const QString &input, int value, const QString &source);
    // The service ends a test by itself ("idle", "route"...).
    void endTest(const QString &id, const QString &reason);
    bool testRunning(const QString &id) const { return m_tests.contains(id); }
    // Whether the running test of `id` was started holding the left stick's navigation (RUY-479).
    bool testHoldsLeftStick(const QString &id) const { return m_tests.contains(id) && m_holds.value(id); }
    // While true the mock plays the service's stick-to-arrow-keys path: a left-stick input past
    // half travel, during a test that does not hold the stick, sends an arrow key to the focused
    // window. Off by default, so no other test is moved by it.
    void setStickNavigates(bool on)
    {
        m_stickNavigates = on;
        m_stickDown.clear();
    }
    QVariantList devices() const { return m_devices; }
    // The three pads again, no test, ListDevices working.
    void resetDevices();

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
    // Tests (RUY-410): the name loses (false) or gets back (true) its owner, with no other change.
    void setNameOwned(bool owned);

private:
    void setDefaultDevices();

    QVariantList m_calls;
    QString m_route = QStringLiteral("shell");
    QString m_instance;
    QString m_profile;
    bool m_pads = false;
    int m_padGeneration = 0;
    bool m_fail = false;
    bool m_holdSaves = false;
    bool m_replaying = false;
    struct HeldCall { quint64 token; QVariantMap args; };
    QList<HeldCall> m_held;
    bool m_listFail = false;
    QVariantList m_devices;
    QSet<QString> m_tests;
    QHash<QString, bool> m_holds;      // device id -> its test holds the left stick (valid while it runs)
    bool m_stickNavigates = false;
    QHash<QString, int> m_stickDown;   // "id/axis" -> the direction held (-1, 1), none: absent
    MockInputProfiles m_profiles;
    QVariantList m_profileCalls;
    QHash<QString, QString> m_forcedStatus;
    QSet<QString> m_forcedOnce;
    QHash<QString, QString> m_confirm;
};
