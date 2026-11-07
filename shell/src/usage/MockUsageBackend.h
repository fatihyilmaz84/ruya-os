#pragma once

#include "UsageBackend.h"

#include <QHash>
#include <QList>
#include <QVariantMap>

// In-memory ledger. Data is per profile: a list of sessions { appId, start (unix s), seconds,
// reason, day "YYYY-MM-DD" }; the day rows are computed from them the way the service does (one
// row per app and day; the session counts on its day). Without data a profile has an empty
// ledger. `setData` fills it (tests), `seedDemo` makes weeks of plausible play relative to a
// date (screenshots, a development run).
class MockUsageBackend final : public UsageBackend
{
    Q_OBJECT

public:
    explicit MockUsageBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh(const QString &profile) override;
    void clearHistory(const QString &profile) override;
    void reportPresence(const QString &profile, const QString &instance, const QString &attention) override;

    void setToday(const QString &today) { m_today = today; }
    void setData(const QString &profile, const QVariantList &sessions) { m_data.insert(profile, sessions); }
    void seedDemo(const QString &profile, const QString &today);
    void setReplyDelay(int ms) { m_delayMs = ms; }
    void failNextClear(const QString &status) { m_failClear = status; }
    void failNextRefresh(const QString &status) { m_failRefresh = status; }
    void touch(const QString &profile) { emit usageChanged(profile); }
    int pendingReplies() const { return m_pending; }
    QVariantMap lastPresence() const { return m_presence; }
    int presenceCount() const { return m_presenceCount; }
    void reset();

private:
    UsageSnapshot snapshotOf(const QString &profile) const;

    QHash<QString, QVariantList> m_data;
    QString m_today;
    int m_delayMs = 0;
    int m_pending = 0;
    QString m_failClear;
    QString m_failRefresh;
    QVariantMap m_presence;
    int m_presenceCount = 0;
};
