#pragma once

#include "RequestSequence.h"

#include <QObject>
#include <QString>
#include <QVariantList>

// What one refresh of the play ledger returns (org.ruyaos.Session1: GetTotals + ListSessions).
// Rows and sessions are plain maps with camelCase keys:
//   row     { appId, day "YYYY-MM-DD", seconds, sessions, longest, first, last }
//   session { appId, appVersion, start, end, seconds, reason, day, open }
struct UsageSnapshot
{
    QString status = QStringLiteral("ok");
    QString today; // "YYYY-MM-DD" in the device time zone
    QVariantList rows;
    QVariantList sessions;
};

// Transport behind the Usage QML singleton (T-247): the ledger of ruya-session over D-Bus, or an
// in-memory mock. Results arrive asynchronously through signals.
class UsageBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    // Reads the ledger of `profile` (the active profile only).
    virtual void refresh(const QString &profile) = 0;
    // Deletes the profile's history (its own, the active one).
    virtual void clearHistory(const QString &profile) = 0;
    // The shell tells who is in front: attention is "active" | "idle" | "locked" | "suspended".
    virtual void reportPresence(const QString &profile, const QString &instance, const QString &attention) = 0;

signals:
    void loaded(const QString &profile, const UsageSnapshot &snapshot);
    // status: see api/dbus/org.ruyaos.Session1.xml
    void clearFinished(const QString &profile, const QString &status);
    // UsageChanged: the ledger of `profile` has new data.
    void usageChanged(const QString &profile);

protected:
    // Replies can arrive out of order: number each refresh when it is sent, report only the
    // newest outcome so far (RequestSequence.h, T-181; a failure counts, T-191).
    quint64 beginRefresh() { return m_seq.begin(); }
    void deliver(quint64 request, const QString &profile, const UsageSnapshot &snapshot)
    {
        if (m_seq.accept(request))
            emit loaded(profile, snapshot);
    }

private:
    RequestSequence m_seq;
};
