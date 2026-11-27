#pragma once

#include "PlayBackend.h"

#include <QHash>
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Play1 (api/dbus/org.ruyaos.Play1.xml): the packages on mounted drives, a
// look inside one, and the install and verify jobs. The install pages (RUY-98) use it.
// Backend: RUYA_SERVICES picks it (ServicesChoice.h). The service (ruya-play,
// RUY-100) does not exist yet, so on Linux the facade stays
// unavailable until it does.
//
// A job's key is the package path for install() and the app id for verify() and remove(). Source records:
// { drive, driveLabel, path, name, kind, size }. Inspect records: see PlayInfo::toVariant.
class Play : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // Candidate packages on mounted drives (data only); refreshed on SourcesChanged.
    Q_PROPERTY(QVariantList sources READ sources NOTIFY sourcesChanged)
    // Key -> { percent, phase } for every job that has reported progress and not finished. When the
    // service loses its bus name the jobs are dropped and every job it ran ends with
    // jobFinished(key, "failed"); when it is back, its job table replaces this map and a job that
    // ended otherwise gets a second jobFinished with the real result (as the Store does).
    Q_PROPERTY(QVariantMap jobs READ jobs NOTIFY jobsChanged)
    // The keys (path or app id) of this session's calls that are not over: sent and not answered yet, or accepted
    // and their job not finished. A page offers no second call for a key in it (a job reports progress only later).
    Q_PROPERTY(QStringList inFlight READ inFlight NOTIFY inFlightChanged)
    // True once the service has answered a list, false again when it is lost.
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)
    // Developer mode (05 7.2): unsigned packages may be installed. An admin's setting, off until the service says.
    Q_PROPERTY(bool developerMode READ developerMode NOTIFY developerModeChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Play(std::unique_ptr<PlayBackend> backend, QObject *parent = nullptr);
    ~Play() override;

    static Play *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList sources() const { return m_sources; }
    QVariantMap jobs() const { return m_jobs; }
    QStringList inFlight() const;
    bool isAvailable() const { return m_available; }
    bool isMock() const { return m_backend->isMock(); }
    bool developerMode() const { return m_developerMode; }

    // Answers with `inspected` (status "ok") or `answered("inspect", path, status)` alone.
    Q_INVOKABLE void inspect(const QString &path);
    // adminApproved: the caller vouches that an admin is signed in or gave the PIN (Profiles1).
    // answered("install", path, status) says whether a job was queued; its end is jobFinished.
    Q_INVOKABLE void install(const QString &path, bool adminApproved);
    Q_INVOKABLE void verify(const QString &appId);
    // Remove an installed .play app (RUY-816): the one way the shell removes one (never Store.uninstall).
    // adminApproved as for install(). answered("remove", appId, status); the job's end is jobFinished with
    // kind "remove". The player's data stays (05 §10).
    Q_INVOKABLE void remove(const QString &appId, bool adminApproved);
    // The build an update of `appId` replaced (RUY-1245): answered("previous", appId, status) ("no-previous" when
    // nothing is kept), then previousRead(appId, { version, build, permissionsAdded, permissionsRemoved }) on "ok".
    Q_INVOKABLE void readPrevious(const QString &appId);
    // Roll `appId` back to that build (RUY-1245): adminApproved as for install(). answered("rollback", appId, status);
    // the job's end is jobFinished with kind "rollback". Saves, prefixes and withdrawn permissions stay.
    Q_INVOKABLE void rollback(const QString &appId, bool adminApproved);
    // Is `appId` ("play.<id>") a .play app, so that Remove (not the Store) uninstalls it? The one place that
    // decides which service removes an app; the service itself answers unknown-app for a Flatpak that is
    // only named play.<x>.
    Q_INVOKABLE bool isPlayApp(const QString &appId) const;
    Q_INVOKABLE void cancel(const QString &key);
    Q_INVOKABLE void refreshSources();
    // answered("developer-mode", "", status): "ok", "forbidden" (adminApproved false) or "failed".
    Q_INVOKABLE void setDeveloperMode(bool on, bool adminApproved);

    // Tests only, and only with the mock backend (otherwise no-op).
    Q_INVOKABLE void mockReset();
    Q_INVOKABLE void mockSetDriveMounted(bool mounted);
    Q_INVOKABLE void mockSetDeveloperMode(bool on);
    Q_INVOKABLE void mockCorruptInstalled(const QString &appId);
    // The app is installed at this build (a game put on the block list after it was installed: oldbad, 7).
    Q_INVOKABLE void mockSetInstalled(const QString &appId, uint build);
    // The installed app keeps this older build for a rollback (as after an update from it).
    Q_INVOKABLE void mockSetPrevious(const QString &appId, uint build);
    Q_INVOKABLE void mockPauseJobs(bool paused);
    // The running job stands still after it reported this percent, until mockPauseJobs(false).
    Q_INVOKABLE void mockPauseAtPercent(int percent);
    // The next method call (any) is answered "failed".
    Q_INVOKABLE void mockFailNext();
    Q_INVOKABLE void mockServiceLost();
    Q_INVOKABLE void mockServiceRegained();
    // The shell restarted while jobs ran: the facade forgets which job is whose and reads the service's table.
    Q_INVOKABLE void mockRestartShell();
    // The mock drive's path of a fixture ("starhopper", "pixelforest.play.zip", ...).
    Q_INVOKABLE QString mockPath(const QString &fixture) const;

signals:
    void sourcesChanged();
    void jobsChanged();
    void inFlightChanged();
    void availableChanged();
    void developerModeChanged();
    void inspected(const QString &path, const QVariantMap &info);
    void previousRead(const QString &appId, const QVariantMap &previous);
    // op "inspect" | "install" | "verify" | "remove" | "previous" | "rollback" | "cancel" | "developer-mode";
    // status: a method status of the XML.
    void answered(const QString &op, const QString &key, const QString &status);
    // status: a JobFinished status of the XML. kind: "install" | "verify" | "remove" | "rollback" ("" when the shell
    // cannot tell);
    // name: the app's display name when the shell knows it (from the service's job table after a restart), else "".
    void jobFinished(const QString &key, const QString &status, const QString &kind, const QString &name);
    void jobsReconciled();

private:
    void setAvailable(bool available);

    // What kind of job a key names and whose it is: from the calls of this session, and from the service's job table
    // (which a restarted shell reads).
    struct JobInfo
    {
        QString kind;
        QString name;
    };
    void finishJob(const QString &key, const QString &status);
    JobInfo infoOf(const QString &key) const;

    std::unique_ptr<PlayBackend> m_backend;
    QHash<QString, QString> m_pending;   // key -> kind of a call not answered yet
    QHash<QString, QString> m_requested; // key -> kind, for a job this session asked for and the service accepted
    QHash<QString, JobInfo> m_listed;
    QVariantList m_sources;
    QVariantMap m_jobs;
    // Keys whose job was given up as failed when the service was lost -> the service's job id.
    QHash<QString, QString> m_lost;
    bool m_available = false;
    bool m_developerMode = false;
};
