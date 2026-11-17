#pragma once

#include "JobBook.h"

#include <QHash>
#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

// One candidate package of ListSources (api/dbus/org.ruyaos.Play1.xml, "Source record").
struct PlaySource
{
    QString drive;      // the drive's id
    QString driveLabel;
    QString path;       // what inspect() and install() take
    QString name;       // file or folder name; nothing was opened
    QString kind;       // "folder" | "zip"
    qulonglong size = 0;

    QVariantMap toVariant() const
    {
        return {
            {QStringLiteral("drive"), drive},
            {QStringLiteral("driveLabel"), driveLabel},
            {QStringLiteral("path"), path},
            {QStringLiteral("name"), name},
            {QStringLiteral("kind"), kind},
            {QStringLiteral("size"), size},
        };
    }
};

// (code, path, message) of 05 §4.5. The shell translates by code and never shows the message.
struct PlayProblem
{
    QString code;
    QString path;
    QString message;
};

// (key, words, risk) of the Inspect record.
struct PlayPermission
{
    QString key;
    QString words;
    QString risk; // "low" | "medium" | "high"
};

// The Inspect record (api/dbus/org.ruyaos.Play1.xml, "Inspect record").
struct PlayInfo
{
    QString path; // the package that was inspected (not in the record: the caller knows it)
    QString id;
    QString name;
    QString summary;
    QString version;
    uint build = 0;
    QString developer;
    QStringList genres;
    QString players;
    QString controller = QStringLiteral("none");
    QString ageLabel; // empty = the package declares none
    qulonglong size = 0;
    QString requirement = QStringLiteral("ok"); // "ok" | "unsupported"
    QString verdict = QStringLiteral("ok");     // "ok" or a JobFinished status
    QString tier = QStringLiteral("unverified"); // "official" | "developer" | "unverified"
    QString signerKeyId;                        // 32 hex characters; empty = none
    QString signerName;
    QString keyState;                           // "new" | "same" | "different"; empty = unsigned
    QList<PlayPermission> permissions;
    QVariantMap art;                            // role -> vetted path
    QStringList screenshots;
    bool revoked = false;
    uint installedBuild = 0;                    // 0 = not installed
    QList<PlayProblem> problems;

    // The record as QML sees it (camelCase keys).
    QVariantMap toVariant() const
    {
        QVariantList perms;
        for (const PlayPermission &p : permissions) {
            perms.append(QVariantMap{{QStringLiteral("key"), p.key},
                                     {QStringLiteral("words"), p.words},
                                     {QStringLiteral("risk"), p.risk}});
        }
        QVariantList probs;
        for (const PlayProblem &p : problems) {
            probs.append(QVariantMap{{QStringLiteral("code"), p.code},
                                     {QStringLiteral("path"), p.path},
                                     {QStringLiteral("message"), p.message}});
        }
        return {
            {QStringLiteral("path"), path},
            {QStringLiteral("id"), id},
            {QStringLiteral("name"), name},
            {QStringLiteral("summary"), summary},
            {QStringLiteral("version"), version},
            {QStringLiteral("build"), build},
            {QStringLiteral("developer"), developer},
            {QStringLiteral("genres"), genres},
            {QStringLiteral("players"), players},
            {QStringLiteral("controller"), controller},
            {QStringLiteral("ageLabel"), ageLabel},
            {QStringLiteral("size"), size},
            {QStringLiteral("requirement"), requirement},
            {QStringLiteral("verdict"), verdict},
            {QStringLiteral("tier"), tier},
            {QStringLiteral("signerKeyId"), signerKeyId},
            {QStringLiteral("signerName"), signerName},
            {QStringLiteral("keyState"), keyState},
            {QStringLiteral("permissions"), perms},
            {QStringLiteral("art"), art},
            {QStringLiteral("screenshots"), screenshots},
            {QStringLiteral("revoked"), revoked},
            {QStringLiteral("installedBuild"), installedBuild},
            {QStringLiteral("problems"), probs},
        };
    }
};

// Transport behind the Play QML singleton: org.ruyaos.Play1 over D-Bus, or an in-memory mock.
// Jobs are named for the facade by a key: the package path for an install, the app id for a verify.
// The job book (shared with the Store, JobBook.h) maps the service's job ids to those keys.
class PlayBackend : public QObject
{
    Q_OBJECT

public:
    explicit PlayBackend(QObject *parent = nullptr)
        : QObject(parent)
        , m_jobs(this)
    {
        connect(&m_jobs, &JobBook::jobProgress, this, &PlayBackend::jobProgress);
        connect(&m_jobs, &JobBook::jobFinished, this, &PlayBackend::jobFinished);
        connect(&m_jobs, &JobBook::jobsListed, this, &PlayBackend::jobsListed);
    }

    virtual bool isMock() const = 0;
    virtual void listSources() = 0;              // answers with sourcesListed
    virtual void inspect(const QString &path) = 0;   // answers with answered("inspect", ...) and inspected
    virtual void install(const QString &path, bool adminApproved) = 0; // answered("install", path, status)
    virtual void verify(const QString &appId) = 0;   // answered("verify", appId, status)
    virtual void cancel(const QString &key) = 0;     // answered("cancel", key, status)
    // Developer mode (05 7.2): read it (answers with developerModeChanged) and set it (answered("developer-mode",
    // "", status); the new value follows as developerModeChanged).
    virtual void readDeveloperMode() = 0;
    virtual void requestDeveloperMode(bool on, bool adminApproved) = 0;
    // The service's job table; answers with jobsListed. Called at start and when the service's name
    // has a new owner.
    virtual void listJobs() = 0;

signals:
    void sourcesListed(const QList<PlaySource> &sources);
    // The drives changed (SourcesChanged): the facade lists again.
    void sourcesChanged();
    void inspected(const QString &path, const PlayInfo &info);
    // A method call was answered: op is "inspect" | "install" | "verify" | "cancel", key the path,
    // app id or job key it was about, status the method status of the XML ("ok" = accepted).
    // A transport failure is "failed".
    void answered(const QString &op, const QString &key, const QString &status);
    void developerModeChanged(bool on);
    void jobProgress(const QString &key, int percent, const QString &phase);
    // status: a JobFinished status of the XML. Only jobs the service accepted finish here.
    void jobFinished(const QString &key, const QString &status);
    // The service's bus name lost its owner: every job it ran is gone. jobKeys: job id -> key.
    void serviceLost(const QHash<QString, QString> &jobKeys);
    void jobsListed(const QList<StoreJob> &jobs);

protected:
    JobBook &jobBook() { return m_jobs; }

private:
    JobBook m_jobs;
};
