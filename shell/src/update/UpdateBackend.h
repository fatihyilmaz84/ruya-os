#pragma once

#include "RequestSequence.h"

#include <QObject>
#include <QString>
#include <QVariantMap>

// The status record of org.ruyaos.Update1 (api/dbus/org.ruyaos.Update1.xml, "GetStatus").
struct UpdateStatus
{
    QString state = QStringLiteral("idle"); // idle | checking | downloading | staged | up-to-date | failed
    QString current;
    QString available;
    QString staged;
    QString channel = QStringLiteral("stable");
    bool autoRestart = true;
    qint64 lastCheck = 0;
    qint64 restartAt = 0; // unix seconds of the announced automatic restart, 0 = none
    int progress = 0;
    bool rollbackAvailable = false;
    QString error;
};

// Transport behind the Update QML singleton: org.ruyaos.Update1 over D-Bus, or an in-memory mock.
// Results arrive asynchronously through signals.
class UpdateBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;                       // reports the status
    virtual void check() = 0;
    virtual void download() = 0;
    // The image job (Update1's Job record, RUY-29): pause keeps the fetched layers, resume goes on
    // from them, cancel stops for good. Download with a paused job resumes it.
    virtual void pauseDownload() = 0;
    virtual void resumeDownload() = 0;
    virtual void cancelDownload() = 0;
    virtual void rollback() = 0;
    virtual void setChannel(const QString &channel) = 0;
    virtual void setAutoRestart(bool enabled) = 0;
    // Input arrived (the caller limits this to once a minute); appRunning: an app is in front.
    // No reply.
    virtual void reportActivity(bool appRunning) = 0;

signals:
    void statusChanged(const UpdateStatus &status);
    // The image job's whole record, keys as the XML's "Job record" (id, state, phase, percent,
    // bytes_done, bytes_total, rate_bps, eta_s, resumable, ...); empty when there has been none.
    void jobChanged(const QVariantMap &job);
    // method: "check" | "download" | "pauseDownload" | "resumeDownload" | "cancelDownload" |
    // "rollback" | "setChannel" | "setAutoRestart"; status: see the XML header ("ok", "busy",
    // "unavailable", "invalid", "forbidden", "failed", "wrong-state", "unsupported").
    void requestFinished(const QString &method, const QString &status);

protected:
    // Replies can arrive out of order (a StatusChanged crosses a GetStatus reply): number each
    // status request when it is sent and report a reply only if no newer one was reported already
    // (RequestSequence.h, T-181, T-191).
    quint64 beginStatusRequest() { return m_statusSeq.begin(); }
    bool acceptStatus(quint64 request) { return m_statusSeq.accept(request); }
    void deliverStatus(quint64 request, const UpdateStatus &status)
    {
        if (acceptStatus(request))
            emit statusChanged(status);
    }
    // The job the same way: a JobChanged signal is numbered when it arrives, so a GetDownloadJob
    // reply sent before it is stale.
    quint64 beginJobRequest() { return m_jobSeq.begin(); }
    bool acceptJob(quint64 request) { return m_jobSeq.accept(request); }
    void deliverJob(quint64 request, const QVariantMap &job)
    {
        if (acceptJob(request))
            emit jobChanged(job);
    }

private:
    RequestSequence m_statusSeq;
    RequestSequence m_jobSeq;
};
