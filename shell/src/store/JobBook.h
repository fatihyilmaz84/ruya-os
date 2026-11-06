#pragma once

#include "RequestSequence.h"

#include <QHash>
#include <QList>
#include <QObject>
#include <QString>

// One record of ListJobs (api/dbus/org.ruyaos.Store1.xml, "ListJobs").
struct StoreJob
{
    QString id;     // the service's name for the job
    QString appId;
    QString kind;   // "install" | "remove" | "update" | "rollback"
    QString state;  // "queued" | "running" | "finished"
    QString status; // "" unless finished: "ok", "failed", ...
    QString reason; // "" or "interrupted" (the service died while it ran)
    uint percent = 0;
    QString phase;
};

// The shell's bookkeeping of the service's jobs, shared by the D-Bus client and the mock so that a
// test with the mock runs the same logic (T-191). The service names its jobs; this maps them to
// app ids for the facade and keeps three kinds of race apart:
//  - A JobProgress/JobFinished can overtake the reply of the Install/Uninstall/Update call that
//    names its job: while such a call is unanswered, signals of unknown jobs are kept and replayed
//    once the reply maps the id.
//  - A ListJobs reply is a snapshot from before some signals that reached the shell first: while a
//    list is pending every signal is logged, and the reply is brought up to date with the ones
//    that arrived after the request was sent (a job that finished meanwhile is not "running").
//  - A job the table lists as running becomes tracked (its later signals map to its app); a
//    tracked job the table lists as finished, whose JobFinished never reached the shell, is
//    reported finished instead of being forgotten silently.
// Replies of ListJobs can arrive out of order or fail: only the newest outcome so far is applied.
class JobBook : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    // Install, Uninstall or Update was sent / its reply named the job / it was refused or failed.
    void callSent() { ++m_calls; }
    void callAnswered(const QString &job, const QString &app);
    void callEnded();

    // A job the shell knows without a call: the mock starts its jobs this way.
    void track(const QString &job, const QString &app) { m_apps.insert(job, app); }
    // The service lost its jobs: forget all of them. Returns what was tracked (job -> app).
    QHash<QString, QString> lose();
    // Forget all jobs without saying anything (test hook).
    void forgetAll();

    // JobProgress / JobFinished of the service.
    void onProgress(const QString &job, uint percent, const QString &phase);
    void onFinished(const QString &job, const QString &status);

    // ListJobs: sent / failed / answered. Only the newest outcome so far is applied (jobsListed).
    quint64 listSent();
    void listFailed(quint64 request);
    void listAnswered(quint64 request, QList<StoreJob> jobs);

signals:
    void jobProgress(const QString &appId, int percent, const QString &phase);
    void jobFinished(const QString &appId, const QString &status);
    void jobsListed(const QList<StoreJob> &jobs);

private:
    struct Signal
    {
        QString job;
        bool finished = false;
        uint percent = 0;
        QString phase;
        QString status;
        quint64 n = 0; // the order in which signals arrived
    };

    void replay(const QString &job, const QString &app);
    void endCall();
    void endList(quint64 request);

    QHash<QString, QString> m_apps;             // tracked job id -> app id
    QHash<QString, QList<Signal>> m_early;      // signals of unknown jobs while a call is unanswered
    int m_calls = 0;
    RequestSequence m_seq;                      // ListJobs outcomes
    int m_lists = 0;                            // ListJobs requests without an outcome yet
    QHash<quint64, quint64> m_since;            // request -> number of the last signal before it
    QList<Signal> m_log;                        // signals that arrived while a list was pending
    quint64 m_signals = 0;
};
