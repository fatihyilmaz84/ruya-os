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
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux and the mock elsewhere, like the
// Store. The service (ruya-play, RUY-100) does not exist yet, so on Linux the facade stays
// unavailable until it does.
//
// A job's key is the package path for install() and the app id for verify(). Source records:
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
    bool isAvailable() const { return m_available; }
    bool isMock() const { return m_backend->isMock(); }
    bool developerMode() const { return m_developerMode; }

    // Answers with `inspected` (status "ok") or `answered("inspect", path, status)` alone.
    Q_INVOKABLE void inspect(const QString &path);
    // adminApproved: the caller vouches that an admin is signed in or gave the PIN (Profiles1).
    // answered("install", path, status) says whether a job was queued; its end is jobFinished.
    Q_INVOKABLE void install(const QString &path, bool adminApproved);
    Q_INVOKABLE void verify(const QString &appId);
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
    Q_INVOKABLE void mockPauseJobs(bool paused);
    // The running job stands still after it reported this percent, until mockPauseJobs(false).
    Q_INVOKABLE void mockPauseAtPercent(int percent);
    // The next method call (any) is answered "failed".
    Q_INVOKABLE void mockFailNext();
    Q_INVOKABLE void mockServiceLost();
    Q_INVOKABLE void mockServiceRegained();
    // The mock drive's path of a fixture ("starhopper", "pixelforest.play.zip", ...).
    Q_INVOKABLE QString mockPath(const QString &fixture) const;

signals:
    void sourcesChanged();
    void jobsChanged();
    void availableChanged();
    void developerModeChanged();
    void inspected(const QString &path, const QVariantMap &info);
    // op "inspect" | "install" | "verify" | "cancel" | "developer-mode"; status: a method status of the XML.
    void answered(const QString &op, const QString &key, const QString &status);
    // status: a JobFinished status of the XML.
    void jobFinished(const QString &key, const QString &status);
    void jobsReconciled();

private:
    void setAvailable(bool available);

    std::unique_ptr<PlayBackend> m_backend;
    QVariantList m_sources;
    QVariantMap m_jobs;
    // Keys whose job was given up as failed when the service was lost -> the service's job id.
    QHash<QString, QString> m_lost;
    bool m_available = false;
    bool m_developerMode = false;
};
