#include "MockUsageBackend.h"

#include <QDate>
#include <QDateTime>
#include <QMap>
#include <QPair>
#include <QTimeZone>
#include <QTimer>

#include <algorithm>

MockUsageBackend::MockUsageBackend(QObject *parent)
    : UsageBackend(parent)
    , m_today(QDate::currentDate().toString(Qt::ISODate))
{
}

void MockUsageBackend::reset()
{
    m_data.clear();
    m_today = QDate::currentDate().toString(Qt::ISODate);
    m_delayMs = 0;
    m_failClear.clear();
    m_failRefresh.clear();
    m_presence.clear();
    m_presenceCount = 0;
}

UsageSnapshot MockUsageBackend::snapshotOf(const QString &profile) const
{
    UsageSnapshot snap;
    snap.today = m_today;
    QMap<QPair<QString, QString>, QVariantMap> rows;
    // Newest first, like ListSessions.
    QList<QVariantMap> sessions;
    const QVariantList data = m_data.value(profile);
    for (const QVariant &v : data)
        sessions.append(v.toMap());
    std::sort(sessions.begin(), sessions.end(), [](const QVariantMap &a, const QVariantMap &b) {
        return a.value(QStringLiteral("start")).toLongLong() > b.value(QStringLiteral("start")).toLongLong();
    });
    for (const QVariantMap &s : std::as_const(sessions)) {
        const QString app = s.value(QStringLiteral("appId")).toString();
        const QString day = s.value(QStringLiteral("day")).toString();
        const int secs = s.value(QStringLiteral("seconds")).toInt();
        const qint64 start = s.value(QStringLiteral("start")).toLongLong();
        const qint64 end = start + secs;
        QVariantMap &row = rows[{day, app}];
        if (row.isEmpty()) {
            row = {{QStringLiteral("appId"), app},
                   {QStringLiteral("day"), day},
                   {QStringLiteral("seconds"), 0},
                   {QStringLiteral("sessions"), 0},
                   {QStringLiteral("longest"), 0},
                   {QStringLiteral("first"), start},
                   {QStringLiteral("last"), end}};
        }
        row[QStringLiteral("seconds")] = row.value(QStringLiteral("seconds")).toInt() + secs;
        row[QStringLiteral("sessions")] = row.value(QStringLiteral("sessions")).toInt() + 1;
        row[QStringLiteral("longest")] = qMax(row.value(QStringLiteral("longest")).toInt(), secs);
        row[QStringLiteral("first")] = qMin(row.value(QStringLiteral("first")).toLongLong(), start);
        row[QStringLiteral("last")] = qMax(row.value(QStringLiteral("last")).toLongLong(), end);
        snap.sessions.append(QVariantMap{
            {QStringLiteral("appId"), app},
            {QStringLiteral("appVersion"), QStringLiteral("1.0")},
            {QStringLiteral("start"), start},
            {QStringLiteral("end"), end},
            {QStringLiteral("seconds"), secs},
            {QStringLiteral("reason"), s.value(QStringLiteral("reason"), QStringLiteral("quit")).toString()},
            {QStringLiteral("day"), day},
            {QStringLiteral("open"), s.value(QStringLiteral("open"), false).toBool()},
        });
    }
    for (auto it = rows.cbegin(); it != rows.cend(); ++it)
        snap.rows.append(it.value());
    return snap;
}

void MockUsageBackend::refresh(const QString &profile)
{
    // Built when asked, delivered after the delay: a late reply carries the data of its time.
    const quint64 request = beginRefresh();
    UsageSnapshot snap = snapshotOf(profile);
    if (!m_failRefresh.isEmpty()) {
        snap = UsageSnapshot{m_failRefresh, {}, {}, {}};
        m_failRefresh.clear();
    }
    ++m_pending;
    QTimer::singleShot(m_delayMs, this, [this, request, profile, snap] {
        --m_pending;
        deliver(request, profile, snap);
    });
}

void MockUsageBackend::clearHistory(const QString &profile)
{
    QString status = QStringLiteral("ok");
    if (!m_failClear.isEmpty()) {
        status = m_failClear;
        m_failClear.clear();
    } else {
        m_data.remove(profile);
    }
    QTimer::singleShot(0, this, [this, profile, status] {
        emit clearFinished(profile, status);
        if (status == QLatin1String("ok"))
            emit usageChanged(profile);
    });
}

void MockUsageBackend::reportPresence(const QString &profile, const QString &instance, const QString &attention)
{
    ++m_presenceCount;
    m_presence = {{QStringLiteral("profile"), profile},
                  {QStringLiteral("instance"), instance},
                  {QStringLiteral("attention"), attention}};
}

void MockUsageBackend::seedDemo(const QString &profile, const QString &today)
{
    m_today = today;
    const QDate base = QDate::fromString(today, Qt::ISODate);
    // (days ago, app, start hour, minutes): a few weeks, mostly the racer, one old chess game.
    struct Demo
    {
        int ago;
        const char *app;
        int hour;
        int minutes;
    };
    static const Demo demo[] = {
        {0, "org.example.Racer", 18, 42},  {0, "org.example.Racer", 20, 20},  {1, "org.example.Puzzle", 19, 40},
        {1, "org.example.Racer", 21, 55},  {2, "org.example.Racer", 17, 75},  {3, "org.example.Racer", 20, 30},
        {3, "org.example.Quest", 14, 25},  {4, "org.example.Quest", 16, 95},  {6, "org.example.Racer", 19, 50},
        {6, "org.example.Puzzle", 21, 20}, {9, "org.example.Racer", 18, 130}, {10, "org.example.Quest", 15, 45},
        {12, "org.example.Racer", 20, 60}, {14, "org.example.Racer", 19, 35}, {15, "org.example.Quest", 11, 80},
        {18, "org.example.Racer", 18, 25}, {21, "org.example.Racer", 20, 70}, {24, "org.example.Puzzle", 17, 15},
        {70, "org.example.Chess", 16, 55},  {71, "org.example.Chess", 16, 40},
    };
    QVariantList sessions;
    for (const Demo &d : demo) {
        const QDate day = base.addDays(-d.ago);
        const qint64 start = QDateTime(day, QTime(d.hour, 0), QTimeZone::UTC).toSecsSinceEpoch();
        sessions.append(QVariantMap{{QStringLiteral("appId"), QString::fromLatin1(d.app)},
                                    {QStringLiteral("start"), start},
                                    {QStringLiteral("seconds"), d.minutes * 60},
                                    {QStringLiteral("reason"), QStringLiteral("quit")},
                                    {QStringLiteral("day"), day.toString(Qt::ISODate)}});
    }
    m_data.insert(profile, sessions);
}
