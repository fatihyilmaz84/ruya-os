#pragma once

#include "InputBackend.h"

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QTimer>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

class Storage;

// QML face of org.ruyaos.Input1 (RUY-409): the shell tells Ruya Input who is in front, so a game
// sees the signed-in profile's virtual pads only while it has the screen (06 §5.1-5.2). The shell is
// the only source of the route; InputRoute.qml works it out and calls setRoute on every change.
// A failed call is logged and sent again with the next change, never waited for; a new owner of the
// name (the service restarted and is back in "shell") gets the current route again at once.
// Since RUY-39 it also lists the connected controllers (ListDevices, asked again on every device
// signal and every new owner of the name), their capabilities and the live button test.
// Since RUY-42 it calls the controller profile members (06 §7) and moves a profile to and from a USB
// drive through the Storage singleton (exportProfile, importProfile), so the pages need no
// plumbing of their own. Since RUY-121 it keeps the players' seats (players, joinPlayer,
// leavePlayer; 06 §11.3): only a seated pad reaches a game, pad n is seat n.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux and the mock elsewhere.
class Input : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The route last asked for ("" before the first call): "shell" | "app" | "overlay" | "locked".
    Q_PROPERTY(QString route READ route NOTIFY routeChanged)
    Q_PROPERTY(QString instance READ instance NOTIFY routeChanged)
    Q_PROPERTY(QString appId READ appId NOTIFY routeChanged)
    Q_PROPERTY(QString profile READ profile NOTIFY routeChanged)
    // The service's answer to the newest call: "" while it is on its way, else a status string of
    // api/dbus/org.ruyaos.Input1.xml, or "failed" when the call failed.
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    // org.ruyaos.Input1 has an owner on the bus (RUY-410). EmergencyReader reads the pads itself
    // when it has been false for 3 s. True until the bus has answered.
    Q_PROPERTY(bool serviceOwned READ serviceOwned NOTIFY serviceOwnedChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)
    // The connected controllers (Input1.ListDevices): maps with the contract's keys (id, instance,
    // name, family, connection, battery, charging, slot, profile, routed). The last good list
    // stays while a newer request fails.
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    // "loading" before the first answer, "ok", or "failed" (the last ListDevices failed).
    Q_PROPERTY(QString devicesState READ devicesState NOTIFY devicesStateChanged)

    // The Confirm button of the active controller (the pad of the last press) for the signed-in
    // profile (06 section 11.2, Input1.ConfirmButton, RUY-603): "family" (as on the controller) |
    // "south" (Bottom) | "east" (Right). "family" until the service has answered. RUY-41's glyphs
    // follow it.
    Q_PROPERTY(QString confirmButton READ confirmButton NOTIFY confirmButtonChanged)
    // The service answered the last read of ConfirmButton.
    Q_PROPERTY(bool confirmButtonAvailable READ confirmButtonAvailable NOTIFY confirmButtonChanged)
    // The signed-in profile's Confirm button per controller (Input1.GetConfirmButtons, RUY-603):
    // device id -> "south" | "east"; a pad that is absent is "family". Read again on a profile
    // switch and when the service appears. A change (setConfirmButton) shows at once; a refusal
    // puts the stored value back.
    Q_PROPERTY(QVariantMap confirmButtons READ confirmButtons NOTIFY confirmButtonsChanged)
    // The last GetConfirmButtons answered "ok" (false: no Input1, the controller page's row is dimmed).
    Q_PROPERTY(bool confirmButtonsAvailable READ confirmButtonsAvailable NOTIFY confirmButtonsChanged)
    // The device of the last press and its family (06 §11.4, RUY-41): a pad as Input1's
    // ActiveInputChanged names it ("xbox", "playstation", "nintendo", "generic", ...), or the
    // family "keyboard" (activeDevice "") after a key from a real keyboard, told apart in the shell
    // by the key event's source device (keyboardSourceOf). A key from the service's navigation
    // device ("RuyaOS Navigation") while the keyboard is active brings the last pad back, since the
    // service announces a pad only when it differs from the one before. "" until the first press.
    // Never changes on a connect. The glyph table (Glyphs.qml) draws the hint bar from these.
    Q_PROPERTY(QString activeDevice READ activeDevice NOTIFY activeInputChanged)
    Q_PROPERTY(QString activeFamily READ activeFamily NOTIFY activeInputChanged)
    // The seated players (Input1.ListPlayers and PlayersChanged, RUY-121, 06 §11.3): maps with the
    // XML's keys (slot 1..4, profile, device_id "" for seat 1 without a pad, held, held_secs), by
    // slot; empty while nobody is signed in. Asked again whenever the name gets a new owner, after
    // the players it held join again (a restarted service knows no seats: seat 1's pad joins as the
    // route's profile, then the others by slot; those answers are not joinFinished). The last good
    // list stays while a newer ListPlayers fails.
    Q_PROPERTY(QVariantList players READ players NOTIFY playersChanged)
    // The pad the shell asked to drive the UI (setNavigator, RUY-38, 06 §11.3), "" for none. It
    // goes with a refusal, the pad leaving the list and a change of the route's profile (the
    // service clears its own then), and is set again when the name gets a new owner, after the
    // players joined again (those answers are not navigatorFinished).
    Q_PROPERTY(QString navigator READ navigator NOTIFY navigatorChanged)

public:
    explicit Input(std::unique_ptr<InputBackend> backend, QObject *parent = nullptr);
    ~Input() override;

    static Input *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    // Who sent a key press, by its source device's name (06 §11.4): "pad" for the service's
    // navigation keys ("RuyaOS Navigation"), "keyboard" for a real keyboard, "" when Qt cannot
    // tell (no name, or Qt's own "core keyboard": a platform that does not name the device, a key
    // the shell made). Only the keys the shell navigates or types with count; media, volume and
    // power keys never switch the glyphs.
    static QString keyboardSourceOf(const QString &deviceName, int key);

    // Every key press of the application passes here (an application event filter).
    bool eventFilter(QObject *watched, QEvent *event) override;

    QString route() const { return m_route; }
    QString instance() const { return m_instance; }
    QString appId() const { return m_appId; }
    QString profile() const { return m_profile; }
    QString status() const { return m_status; }
    bool isMock() const { return m_backend->isMock(); }
    bool serviceOwned() const { return m_backend->serviceOwned(); }

    // Sends the route unless it is the one already asked for and that call did not fail.
    Q_INVOKABLE void setRoute(const QString &route, const QString &instance, const QString &appId,
                              const QString &profile);

    QVariantList devices() const { return m_devices; }
    QString devicesState() const { return m_devicesState; }
    QString confirmButton() const { return m_confirm; }
    bool confirmButtonAvailable() const { return m_confirmAvailable; }
    QVariantMap confirmButtons() const { return m_confirms; }
    bool confirmButtonsAvailable() const { return m_confirmsAvailable; }
    QString activeDevice() const { return m_activeDevice; }
    QString activeFamily() const { return m_activeFamily; }
    // Input1.SetConfirmButton(profile, device, mode) for one controller of the signed-in profile
    // (RUY-603); a refusal (any status but "ok", or a failed call) is the signal
    // confirmButtonRefused(deviceId, status).
    Q_INVOKABLE void setConfirmButton(const QString &deviceId, const QString &mode);
    // Asks GetConfirmButtons again (a controller page when it opens).
    Q_INVOKABLE void refreshConfirmButtons();

    QVariantList players() const { return m_players; }
    // Input1.JoinPlayer(device_id, profile): seats the profile on the pad (06 §11.3: player 1's
    // own profile moves seat 1 to that pad, a seated profile moves and keeps its seat, else the
    // lowest free seat). Check the profile's PIN (Profiles1) first: the service never sees it. The
    // answer is joinFinished; `players` follows from PlayersChanged.
    Q_INVOKABLE void joinPlayer(const QString &deviceId, const QString &profile);
    // Input1.LeavePlayer(slot) for seats 2..4; the answer is leaveFinished.
    Q_INVOKABLE void leavePlayer(int slot);
    QString navigator() const { return m_navigator; }
    // Input1.SetNavigator(device_id) (RUY-38): while set only that pad navigates the shell, every key
    // including Guide (the pad of "Who's playing?", RUY-122); "" clears it. The service announces the
    // pad as the active input at once. The answer is navigatorFinished.
    Q_INVOKABLE void setNavigator(const QString &deviceId);

    // Asks ListDevices again (Settings > Controllers' "Try again").
    Q_INVOKABLE void refreshDevices();
    // GetCapabilities(device_id): the answer arrives as capabilitiesFinished.
    Q_INVOKABLE void requestCapabilities(const QString &deviceId);
    // The live button test: StartTest's answer arrives as testStartFinished, the inputs as
    // testInput, its end (StopTest included) as testEnded. holdLeftStick: the pad's left stick sends
    // no arrow keys while this test runs (only the Left stick page sets it).
    Q_INVOKABLE void startTest(const QString &deviceId, bool holdLeftStick);
    Q_INVOKABLE void stopTest(const QString &deviceId);

    // Controller profiles (RUY-42, api/dbus/org.ruyaos.Input1.xml): one call each, the answer as the
    // signal named after it. `profile` is the console profile ("p1"); summaries are maps with the
    // XML's keys (id, name, scope, scope_id, inherits, builtin, assigned, global_slot, match_family,
    // match_device, layout, remapped, left_stick_changed, right_stick_changed, changed). A refused
    // save's "path: message" lines are written to the journal; never show them as they are.
    Q_INVOKABLE void listProfiles(const QString &profile);
    Q_INVOKABLE void getProfile(const QString &profile, const QString &profileId);
    Q_INVOKABLE void saveProfile(const QString &profile, const QString &json);
    Q_INVOKABLE void validateProfile(const QString &json);
    Q_INVOKABLE void deleteProfile(const QString &profile, const QString &profileId);
    Q_INVOKABLE void assignProfile(const QString &profile, const QString &scope, const QString &scopeId,
                                   const QString &profileId);
    Q_INVOKABLE void getEffectiveProfile(const QString &profile, const QString &deviceId, const QString &appId);
    // RUY-468: a console profile (deleted, or a temporary guest that went) loses its controller
    // profiles; the answer is consoleProfileForgotten, a status other than "ok" is also logged
    // (never retried: the next start's sweep does). Profiles calls both (06 §7 "Storage").
    Q_INVOKABLE void forgetConsoleProfile(const QString &profile);
    // The console profiles that have controller profiles stored; the answer is
    // storedConsoleProfilesListed.
    Q_INVOKABLE void storedConsoleProfiles();
    // Export: GetProfile, then Storage.saveReport of one file named exportFileName(profile) onto
    // the volume; the answer is exportFinished with GetProfile's status when that failed, else
    // SaveReport's ("ok", "read-only", "full", "unsupported", ...), "busy" while an export runs.
    Q_INVOKABLE void exportProfile(const QString &profile, const QString &profileId, const QString &volumeId);
    // Import: Storage.readFile (capped at 64 KiB before it is read), ValidateProfile, SaveProfile and,
    // for a profile of scope "global", AssignProfile so it applies; the answer is importFinished
    // with the first status that was not "ok" (ReadFile's "too-large", "not-text", "not-found"...;
    // Input1's "invalid", "not-allowed"...), "busy" while an import runs. With a `targetId`, a global
    // profile is saved under that id with the `match` of `targetSlot` ("" = none, all controllers;
    // "family:<f>"; "device:<id>") and assigned there (RUY-572: the slot the page edits).
    Q_INVOKABLE void importProfile(const QString &profile, const QString &volumeId, const QString &fileName,
                                   const QString &targetId = QString(), const QString &targetSlot = QString());
    // "RuyaOS-controls-<profile>-<yyyy-mm-dd>.json" for today (SaveReport's name rule).
    Q_INVOKABLE QString exportFileName(const QString &profile) const;
    // The profile members as the client calls them: [{ name, in: [...], out: [...] }] (the XML's).
    Q_INVOKABLE QVariantList profileMethods() const;
    // Where export and import read and write (the Storage singleton; set by create()).
    void setStorage(Storage *storage);

    // Tests only, and only with the mock backend (otherwise empty or no-ops).
    // A pad presses: the service announces it as the active input.
    Q_INVOKABLE void mockActiveInput(const QString &deviceId, const QString &family);
    // A key press whose source device has this name, through the same path as a real key event
    // (any backend: the keyboard is told apart in the shell).
    Q_INVOKABLE void mockKeyFrom(const QString &deviceName, int key);
    // The service announces that a pad is being played (UserActive).
    Q_INVOKABLE void mockUserActive();
    // The mode the mock service holds for a controller of a console profile ("family" with none).
    Q_INVOKABLE QString mockConfirmButton(const QString &profile, const QString &deviceId) const;
    // While true the mock's GetConfirmButtons answers 300 ms late, with what it held when asked
    // (the late-reply test).
    Q_INVOKABLE void mockDelayConfirmButtons(bool delayed);
    // The pad presses and lets go `button` ("south", "east", "start", "guide", "dpad_up",
    // "dpad_down", "dpad_left", "dpad_right", "l1", "r1"): by the service's rule (06 §11.3) its
    // navigation key reaches the focused window the way a key from "RuyaOS Navigation" does, or
    // nothing does and the mock service may send ForeignInput.
    Q_INVOKABLE void mockPadButton(const QString &deviceId, const QString &button);
    // The pad the mock service holds as the navigator ("" for none).
    Q_INVOKABLE QString mockNavigator() const;
    // The seats the mock service holds now (player records), and a status every later JoinPlayer
    // answers without changing anything ("" clears it).
    Q_INVOKABLE QVariantList mockPlayers() const;
    Q_INVOKABLE void mockFailJoin(const QString &status);
    // How long the mock service holds a removed seated pad's seat (RUY-627; 60000 ms by default).
    // Also the replay deadline (RUY-644); mockReplayPending is the players still queued to join again.
    Q_INVOKABLE void mockSeatHoldMs(int ms);
    // PlayersChanged reaches the shell after `ms` (a slow bus; 0 by default; RUY-664).
    Q_INVOKABLE void mockPlayersDelayMs(int ms);
    // DevicesChanged after a pad's removal reaches the shell after `ms` (0 by default; RUY-707: the
    // players' change may come first).
    Q_INVOKABLE void mockRemovalDevicesDelayMs(int ms);
    Q_INVOKABLE int mockReplayPending() const;
    // Every SetRoute that reached the mock service: [{ route, instance, appId, profile }].
    Q_INVOKABLE QVariantList mockCalls() const;
    Q_INVOKABLE void mockClearCalls();
    // What the mock service holds now, and whether it has virtual pads (and how often it made them).
    Q_INVOKABLE QString mockServiceRoute() const;
    Q_INVOKABLE QString mockServiceInstance() const;
    Q_INVOKABLE QString mockServiceProfile() const;
    Q_INVOKABLE bool mockPads() const;
    Q_INVOKABLE int mockPadGeneration() const;
    // While true every call fails ("failed"), as with no service on the bus.
    Q_INVOKABLE void mockFail(bool fail);
    // The service restarts (route "shell", no pads) and its name gets a new owner.
    Q_INVOKABLE void mockRestart();
    // The service's name loses or regains its owner (RUY-410: the service is gone, or masked).
    Q_INVOKABLE void mockNameOwned(bool owned);
    // Devices (RUY-39): a pad connects or changes (a record; `capabilities` optional), or goes.
    Q_INVOKABLE void mockAddDevice(const QVariantMap &device);
    Q_INVOKABLE void mockRemoveDevice(const QString &id);
    // While true ListDevices and GetCapabilities fail.
    Q_INVOKABLE void mockListFail(bool fail);
    // The pad sends an input during its test; the service ends a test by itself; is one running.
    Q_INVOKABLE void mockTestInput(const QString &id, const QString &input, int value, const QString &source);
    Q_INVOKABLE void mockEndTest(const QString &id, const QString &reason);
    Q_INVOKABLE bool mockTestRunning(const QString &id) const;
    // Whether the running test of the pad holds the left stick's navigation (RUY-479), and whether the
    // mock plays the service's stick-to-arrow-keys path (default off).
    Q_INVOKABLE bool mockTestHoldsLeftStick(const QString &id) const;
    Q_INVOKABLE void mockStickNavigates(bool on);
    // The mock's three pads again, no test running, ListDevices working.
    Q_INVOKABLE void mockResetDevices();
    // Controller profiles (RUY-42): every call that reached the mock as { method, args } (args by
    // the XML's names), and the profiles back to the built-ins only.
    Q_INVOKABLE QVariantList mockProfileCalls() const;
    Q_INVOKABLE void mockClearProfileCalls();
    Q_INVOKABLE void mockResetProfiles();
    // Every later call of `method` answers `status` ("" = as the mock service would; reset by
    // mockResetProfiles): a refused save for the Controls in games pages (RUY-465).
    Q_INVOKABLE void mockSetProfileStatus(const QString &method, const QString &status);
    // While true SaveProfile calls wait (recorded, not carried out); false carries them out in order (RUY-595).
    Q_INVOKABLE void mockHoldSaves(bool hold);
    Q_INVOKABLE void mockSetProfileStatusOnce(const QString &method, const QString &status);
    // The console profiles the mock holds controller profiles for (StoredConsoleProfiles), and one
    // more as if it were left on disk (an orphan for the start sweep, RUY-468).
    Q_INVOKABLE QStringList mockStoredConsoleProfiles() const;
    Q_INVOKABLE void mockAddStoredConsoleProfile(const QString &profile);
    // While true StoredConsoleProfiles calls wait (recorded, not answered); false answers them with
    // what is stored then (the start sweep's race, RUY-468).
    Q_INVOKABLE void mockHoldStoredConsoleProfiles(bool hold);

signals:
    void routeChanged();
    void statusChanged();
    void serviceOwnedChanged();
    void devicesChanged();
    void devicesStateChanged();
    void confirmButtonChanged();
    void confirmButtonsChanged();
    void confirmButtonRefused(const QString &deviceId, const QString &status);
    void activeInputChanged();
    void playersChanged();
    // JoinPlayer and LeavePlayer answered: a status of the XML ("ok", "unknown-device",
    // "unknown-profile", "not-allowed", "full", "invalid") or "failed" when the call failed; slot is
    // the seat taken, 0 unless "ok".
    void joinFinished(const QString &deviceId, const QString &profile, const QString &status, int slot);
    void leaveFinished(int slot, const QString &status);
    void navigatorChanged();
    // SetNavigator answered: "ok", "not-allowed", "unknown-device", or "failed" when the call failed.
    void navigatorFinished(const QString &deviceId, const QString &status);
    // Input1.ForeignInput (RUY-38, 06 §11.3): a pad that does not navigate asked for something while
    // a profile is signed in: "press" (an unseated pad's button, at most once a second), "guide" (its
    // Guide), "player-guide" (the Guide of a player in seat 2-4: journaled, nothing shown until a
    // players' Hub is designed).
    void foreignInput(const QString &deviceId, const QString &kind);
    // Someone is playing with a pad in the app in front (Input1.UserActive, RUY-588): the shell's
    // own keys do not see that input. IdleClock counts it.
    void userActive();
    void capabilitiesFinished(const QString &deviceId, const QString &status, const QVariantList &capabilities);
    void testStartFinished(const QString &deviceId, const QString &status);
    void testInput(const QString &deviceId, const QString &input, int value, const QString &source);
    void testEnded(const QString &deviceId, const QString &reason);
    // The answers of the profile calls; status is a string of the XML, or "failed" when the call
    // failed.
    void profilesListed(const QString &profile, const QString &status, const QVariantList &profiles);
    void profileFetched(const QString &profile, const QString &profileId, const QString &status, const QString &json);
    void profileSaved(const QString &profile, const QString &status, const QString &profileId, const QStringList &errors);
    void profileValidated(const QString &status, const QStringList &errors);
    void profileDeleted(const QString &profile, const QString &profileId, const QString &status);
    void profileAssigned(const QString &profile, const QString &scope, const QString &scopeId,
                         const QString &profileId, const QString &status);
    void effectiveProfileFetched(const QString &profile, const QString &deviceId, const QString &appId,
                                 const QString &status, const QString &json, const QStringList &chain);
    void consoleProfileForgotten(const QString &profile, const QString &status);
    void storedConsoleProfilesListed(const QString &status, const QStringList &profiles);
    // The service's ProfilesChanged.
    void profilesChanged(const QString &profile);
    // fileName is the name the export used (also when it failed).
    void exportFinished(const QString &profile, const QString &profileId, const QString &volumeId,
                        const QString &status, const QString &fileName);
    // profileId is the imported profile's id once SaveProfile took it; errors are the service's
    // lines of a refused file (also in the journal).
    void importFinished(const QString &profile, const QString &volumeId, const QString &fileName,
                        const QString &status, const QString &profileId, const QStringList &errors);

private:
    void setActiveInput(const QString &deviceId, const QString &family);
    // After a new owner of the name: the players last known join again (RUY-121), each once the
    // service lists its pad (continueReplay, on every device list).
    void replayPlayers();
    void continueReplay();
    struct Replay
    {
        QString device;
        QString profile;
        uint slot = 0;
    };
    void noteKeyFrom(const QString &deviceName, int key);
    void send();
    // What a profile call's answer is for.
    enum class Purpose { Plain, ExportGet, ImportValidate, ImportSave, ImportAssign };
    void callProfile(const QString &method, const QVariantMap &args, Purpose purpose);
    void onProfileReply(quint64 token, const QString &method, const QVariantMap &args, const QVariantMap &reply);
    void finishExport(const QString &status);
    void finishImport(const QString &status, const QStringList &errors = {});
    void showConfirmButtons(bool force);
    void forgetConfirmButtons();
    struct Transfer
    {
        bool active = false;
        bool storageStage = false; // waiting for Storage (saveReport, readFile)
        QString profile;
        QString profileId;
        QString volumeId;
        QString fileName;
        QString text;
        QString targetId;   // import: the id the profile is saved under ("" keeps the file's own)
        QString targetSlot; // import: the slot it is assigned to ("", "family:<f>", "device:<id>")
    };

    std::unique_ptr<InputBackend> m_backend;
    QString m_route;
    QString m_instance;
    QString m_appId;
    QString m_profile;
    QString m_status;
    QVariantList m_devices;
    QVariantList m_players;
    QHash<QString, int> m_replays;   // "device|profile" -> JoinPlayer calls of the replay not answered
    QList<Replay> m_replayQueue;     // players to join again once their pad is listed, by slot
    QTimer m_replayTimer;            // drops the players whose pad is not back within the hold
    int m_replayHoldMs = 60000;      // the service's SEAT_HOLD
    QString m_replayProfile;         // the profile the queue was made for
    QString m_replayNavigator;       // the navigator to set again once its pad is listed
    int m_navigatorReplays = 0;      // SetNavigator calls of the replay not answered
    QString m_navigator;
    void setNavigatorShown(const QString &deviceId);
    QString m_devicesState = QStringLiteral("loading");
    QString m_confirm = QStringLiteral("family");
    bool m_confirmAvailable = false;
    QVariantMap m_confirms;        // shown: what the service holds, with the changes on their way
    QVariantMap m_confirmsStored;  // what the service answered or took
    QHash<QString, QString> m_confirmsWanted;  // device -> the newest mode on its way
    QHash<QString, int> m_confirmsInFlight;    // device -> SetConfirmButton calls not answered yet
    bool m_confirmsAvailable = false;
    QString m_activeDevice;
    QString m_activeFamily;
    QString m_padDevice;           // the last pad Input1 announced (back after the keyboard)
    QString m_padFamily;
    QSet<QString> m_keySourcesLogged;
    quint64 m_nextToken = 1;
    QHash<quint64, Purpose> m_purposes;
    QPointer<Storage> m_storage;
    Transfer m_export;
    Transfer m_import;
};
