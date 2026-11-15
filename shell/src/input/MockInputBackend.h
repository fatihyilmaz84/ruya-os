#pragma once

#include "InputBackend.h"
#include "MockInputProfiles.h"

#include <QElapsedTimer>
#include <QHash>
#include <QSet>
#include <QTimer>
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
// Players (RUY-121): the service's seats and statuses (routing.rs, seats.rs): a profile change seats
// the new profile in seat 1 on the pad of the last sendActiveInput since the change before ("" for
// none), Join/Leave follow rules (a) to (e), and the device records' slot and profile follow. A
// removed seated pad holds its seat (RUY-627: held, held_secs; 60 s, setSeatHoldMs for tests): the
// same id added again within the hold sits there again, and at its end the seat is freed (2-4) or
// seat 1 keeps its profile without a pad. One PlayersChanged as a hold starts and one as it ends.
// Like pads (another id) are the service's rule only. PlayersChanged is not heard while the name
// has no owner. Who drives the UI (RUY-38, routing.rs `navigates`): every pad while nobody is
// signed in, else only the navigator (SetNavigator) or seat 1's pad (not while its seat is held);
// padButton plays a pad's press by that rule (its navigation key, or ForeignInput "press" at most
// once a second, "guide", "player-guide"). The navigator goes with its pad, a profile change and a
// restart (the caller leaving the bus is the service's rule only).
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
    // The Confirm button per console profile and controller (RUY-40, RUY-603); the property is the
    // active pad's for the route's profile.
    void readConfirmButton() override;
    void readConfirmButtons(const QString &profile) override;
    void joinPlayer(const QString &deviceId, const QString &profile) override;
    void leavePlayer(uint slot) override;
    void refreshPlayers() override;
    void setNavigator(const QString &deviceId) override;
    // Tests: a pad's button is pressed and let go ("south", "east", "start", "guide", "dpad_up",
    // "dpad_down", "dpad_left", "dpad_right", "l1", "r1"). The Qt key the service would send the
    // shell on "RuyaOS Navigation" (after the pad's Confirm choice), or 0 when the rule gives the
    // shell nothing: then a ForeignInput may follow, as the service sends it.
    int padButton(const QString &deviceId, const QString &button);
    QString navigator() const { return m_navigator; }
    // Tests: the seats the mock service holds now (player records, by slot).
    QVariantList players() const { return playerList(); }
    // Tests: every later JoinPlayer answers `status` and changes nothing ("" clears it).
    void setFailJoin(const QString &status) { m_failJoin = status; }
    // Tests: how long a seat waits for its removed pad (60000 ms, the service's SEAT_HOLD).
    void setSeatHoldMs(int ms) { m_seatHoldMs = ms; }
    // Tests: the press of a pad is announced (ActiveInputChanged); the property follows that pad.
    void sendActiveInput(const QString &deviceId, const QString &family);
    // Tests: the mode stored for a controller of a console profile ("family" when none).
    QString confirmButtonOf(const QString &profile, const QString &deviceId) const
    {
        return m_confirm.value(profile).value(deviceId, QStringLiteral("family")).toString();
    }
    // Tests: GetConfirmButtons answers 300 ms late, with what was held when it was asked.
    void setConfirmButtonsDelayed(bool delayed) { m_confirmsDelayed = delayed; }
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
        m_confirmsDelayed = false;
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
    // A seat: a profile on a pad ("" = none); an empty profile is an empty seat. heldUntil: the
    // m_clock time (ms) its hold of a removed pad ends, 0 when it is not held.
    struct Seat
    {
        QString profile;
        QString device;
        qint64 heldUntil = 0;
    };
    // The holds that ran out are ended, and the timer is set for the next one.
    void expireHolds();
    QVariantList playerList() const;
    int seatOfDevice(const QString &deviceId) const;
    bool navigates(const QString &deviceId) const;
    // After the seats changed from `before`: the device records follow, PlayersChanged is sent.
    void seatsChanged(const QVariantList &before);
    bool applySeatsToDevices();

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
    QHash<QString, QVariantMap> m_confirm;   // profile -> device id -> "south" | "east"
    bool m_confirmsDelayed = false;
    QString m_activeDevice;
    QList<Seat> m_seats;           // 4 while a profile is signed in (index 0 is seat 1), else none
    QString m_padSinceChange;      // the pad of the last press since the profile last changed
    QString m_navigator;           // SetNavigator's pad ("" = none)
    QHash<QString, qint64> m_foreignPress;   // device id -> m_clock time of its last ForeignInput "press"
    QString m_failJoin;
    int m_seatHoldMs = 60000;
    QElapsedTimer m_clock;         // the time base of the holds
    QTimer m_holdTimer;            // fires when the next hold ends
};
