#pragma once

#include "UsageBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <QSet>

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
    // The history list ends before the ledger's oldest session: loadMore() reads the next page.
    Q_PROPERTY(bool more READ hasMore NOTIFY dataChanged)
    // The history holds the most the service lists (kMaxSessions): older sessions exist but cannot be shown.
    Q_PROPERTY(bool capped READ isCapped NOTIFY dataChanged)
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
    bool hasMore() const { return m_more; }
    bool isCapped() const { return m_capped; }

    // The service lists at most this many sessions (MAX_LIST in ruya-session); the history pages in 60 at a time.
    static constexpr int kPageSize = 60;
    static constexpr int kMaxSessions = 1000;

    // Reads the active profile's ledger again.
    Q_INVOKABLE void refresh();
    // An Activity page tells whether it is on screen (RUY-48). The ledger is read again when one
    // appears, and on UsageChanged (every 30 s while a game runs) only while at least one is shown.
    Q_INVOKABLE void setWatching(QObject *page, bool on);
    // The history asks for its next page (60 more sessions); a no-op when `more` is false.
    Q_INVOKABLE void loadMore();
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
    Q_INVOKABLE int mockReadCount() const;  // reads started since mockReset
    Q_INVOKABLE int mockLastLimit() const;  // the session limit of the last one
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
    int m_pages = 1;      // pages of the history asked for
    bool m_more = false;
    bool m_capped = false;
    QSet<QObject *> m_watchers;
};
