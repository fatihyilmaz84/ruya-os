#pragma once

#include "UsageBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of the play ledger (T-247, org.ruyaos.Session1): what the active profile played, for
// the Activity pages. It asks for the active profile only (the service refuses anything else) and
// forgets everything when the profile changes. Backend: RUYA_SERVICES=mock|dbus; the default is
// D-Bus on Linux and the mock elsewhere, like Session and Profiles.
//
// The numbers the pages show are computed here (UsageStats) from the service's day rows and
// sessions; the words are the pages' (DurationText and qsTr).
class Usage : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The active profile's ledger has been read (false while loading, after a failure, and with no profile).
    Q_PROPERTY(bool ready READ isReady NOTIFY readyChanged)
    // "ok" | the failing status of the last read ("failed", "not-allowed", ...); "" before the first.
    Q_PROPERTY(QString status READ status NOTIFY readyChanged)
    // Today's date "YYYY-MM-DD" in the device time zone, as the service says.
    Q_PROPERTY(QString today READ today NOTIFY dataChanged)
    // Nothing recorded for this profile yet (or it was cleared).
    Q_PROPERTY(bool empty READ isEmpty NOTIFY dataChanged)
    Q_PROPERTY(QVariantMap week READ week NOTIFY dataChanged)
    Q_PROPERTY(QVariantList top READ top NOTIFY dataChanged)
    Q_PROPERTY(QVariantList history READ history NOTIFY dataChanged)
    Q_PROPERTY(QVariantMap highlights READ highlights NOTIFY dataChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Usage(std::unique_ptr<UsageBackend> backend, QObject *parent = nullptr);
    ~Usage() override;

    static Usage *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    bool isReady() const { return m_ready; }
    QString status() const { return m_status; }
    QString today() const { return m_today; }
    bool isEmpty() const { return m_rows.isEmpty() && m_sessions.isEmpty(); }
    QVariantMap week() const { return m_week; }
    QVariantList top() const { return m_top; }
    QVariantList history() const { return m_history; }
    QVariantMap highlights() const { return m_highlights; }
    bool isMock() const { return m_backend->isMock(); }

    // Reads the active profile's ledger again (the pages call it when they open).
    Q_INVOKABLE void refresh();
    // One app's numbers: { total, sessions, first, last, longest, average, strip, playedDays }.
    Q_INVOKABLE QVariantMap game(const QString &appId) const;
    // Deletes the active profile's history; the answer comes as clearFinished.
    Q_INVOKABLE void clearHistory();
    // The shell reports who is in front. `instance` is the foreground app's ("" for the shell);
    // attention is "active" | "idle" | "locked" | "suspended". The active profile is added here.
    Q_INVOKABLE void reportPresence(const QString &instance, const QString &attention);
    // How many days ago a "YYYY-MM-DD" day was, counted from today (0 = today); -1 if unknown.
    Q_INVOKABLE int daysAgo(const QString &day) const;

    // Tests only, and only with the mock backend (otherwise no-ops).
    Q_INVOKABLE void mockReset();
    // Replaces a profile's sessions: [{ appId, start (unix s), seconds, reason?, day "YYYY-MM-DD" }].
    Q_INVOKABLE void mockSetData(const QString &profile, const QVariantList &sessions, const QString &today);
    Q_INVOKABLE void mockSeedDemo(const QString &profile, const QString &today);
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE void mockFailNextClear(const QString &status);
    Q_INVOKABLE void mockFailNextRefresh(const QString &status); // the next read answers with this status
    Q_INVOKABLE void mockTouch(const QString &profile); // UsageChanged
    Q_INVOKABLE int mockPendingReplies() const;
    Q_INVOKABLE QVariantMap mockLastPresence() const;
    Q_INVOKABLE int mockPresenceCount() const;

signals:
    void readyChanged();
    void dataChanged();
    // status: "ok" | "not-allowed" | "failed" ...; the data is read again after "ok".
    void clearFinished(const QString &status);

private:
    void onLoaded(const QString &profile, const UsageSnapshot &snapshot);
    void forget();
    QString activeProfile() const;

    std::unique_ptr<UsageBackend> m_backend;
    QQmlEngine *m_engine = nullptr;
    bool m_ready = false;
    QString m_status;
    QString m_today;
    QVariantList m_rows;
    QVariantList m_sessions;
    QVariantMap m_week;
    QVariantList m_top;
    QVariantList m_history;
    QVariantMap m_highlights;
};
