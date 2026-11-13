#pragma once

#include "InputBackend.h"

#include <QHash>
#include <QObject>
#include <QPointer>
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
// plumbing of their own.
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

    // The Confirm button of the signed-in profile (06 section 11.2): "family" (as on the controller)
    // | "south" (Bottom) | "east" (Right). "family" until the service has answered. Changing it
    // (setConfirmButton) shows at once; a refusal puts the stored value back.
    Q_PROPERTY(QString confirmButton READ confirmButton NOTIFY confirmButtonChanged)
    // The service answered the last read of ConfirmButton (false: no Input1, the row is dimmed).
    Q_PROPERTY(bool confirmButtonAvailable READ confirmButtonAvailable NOTIFY confirmButtonChanged)
    // The pad of the last press (Input1.ActiveInputChanged) and its family ("xbox", "playstation",
    // "nintendo", "generic", ...); "" until a pad has pressed since the shell started. RUY-41 builds
    // the glyph sets on these two.
    Q_PROPERTY(QString activeDevice READ activeDevice NOTIFY activeInputChanged)
    Q_PROPERTY(QString activeFamily READ activeFamily NOTIFY activeInputChanged)

public:
    explicit Input(std::unique_ptr<InputBackend> backend, QObject *parent = nullptr);
    ~Input() override;

    static Input *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

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
    QString activeDevice() const { return m_activeDevice; }
    QString activeFamily() const { return m_activeFamily; }
    // Input1.SetConfirmButton(profile, mode) for the signed-in profile; a refusal (any status but
    // "ok", or a failed call) is the signal confirmButtonRefused(status).
    Q_INVOKABLE void setConfirmButton(const QString &mode);

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
    // Export: GetProfile, then Storage.saveReport of one file named exportFileName(profile) onto
    // the volume; the answer is exportFinished with GetProfile's status when that failed, else
    // SaveReport's ("ok", "read-only", "full", "unsupported", ...), "busy" while an export runs.
    Q_INVOKABLE void exportProfile(const QString &profile, const QString &profileId, const QString &volumeId);
    // Import: Storage.readFile (capped at 64 KiB before it is read), ValidateProfile, SaveProfile and,
    // for a profile of scope "global", AssignProfile so it applies; the answer is importFinished
    // with the first status that was not "ok" (ReadFile's "too-large", "not-text", "not-found"...;
    // Input1's "invalid", "not-allowed"...), "busy" while an import runs.
    Q_INVOKABLE void importProfile(const QString &profile, const QString &volumeId, const QString &fileName);
    // "RuyaOS-controls-<profile>-<yyyy-mm-dd>.json" for today (SaveReport's name rule).
    Q_INVOKABLE QString exportFileName(const QString &profile) const;
    // The profile members as the client calls them: [{ name, in: [...], out: [...] }] (the XML's).
    Q_INVOKABLE QVariantList profileMethods() const;
    // Where export and import read and write (the Storage singleton; set by create()).
    void setStorage(Storage *storage);

    // Tests only, and only with the mock backend (otherwise empty or no-ops).
    // A pad presses: the service announces it as the active input.
    Q_INVOKABLE void mockActiveInput(const QString &deviceId, const QString &family);
    // The mode the mock service holds for a console profile.
    Q_INVOKABLE QString mockConfirmButton(const QString &profile) const;
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

signals:
    void routeChanged();
    void statusChanged();
    void serviceOwnedChanged();
    void devicesChanged();
    void devicesStateChanged();
    void confirmButtonChanged();
    void confirmButtonRefused(const QString &status);
    void activeInputChanged();
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
    void send();
    // What a profile call's answer is for.
    enum class Purpose { Plain, ExportGet, ImportValidate, ImportSave, ImportAssign };
    void callProfile(const QString &method, const QVariantMap &args, Purpose purpose);
    void onProfileReply(quint64 token, const QString &method, const QVariantMap &args, const QVariantMap &reply);
    void finishExport(const QString &status);
    void finishImport(const QString &status, const QStringList &errors = {});
    struct Transfer
    {
        bool active = false;
        bool storageStage = false; // waiting for Storage (saveReport, readFile)
        QString profile;
        QString profileId;
        QString volumeId;
        QString fileName;
        QString text;
    };

    std::unique_ptr<InputBackend> m_backend;
    QString m_route;
    QString m_instance;
    QString m_appId;
    QString m_profile;
    QString m_status;
    QVariantList m_devices;
    QString m_devicesState = QStringLiteral("loading");
    QString m_confirm = QStringLiteral("family");
    QString m_previousConfirm = QStringLiteral("family");
    bool m_confirmAvailable = false;
    QString m_activeDevice;
    QString m_activeFamily;
    quint64 m_nextToken = 1;
    QHash<quint64, Purpose> m_purposes;
    QPointer<Storage> m_storage;
    Transfer m_export;
    Transfer m_import;
};
