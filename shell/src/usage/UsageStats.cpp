#include "UsageStats.h"

#include <QDate>
#include <QHash>

#include <algorithm>

namespace UsageStats {
namespace {
constexpr int LapsedDays = 60;
constexpr int TopWindowDays = 30;

QString key(const char *name) { return QString::fromLatin1(name); }

int sinceToday(const QString &day, const QDate &today)
{
    const QDate d = QDate::fromString(day, Qt::ISODate);
    return d.isValid() ? int(d.daysTo(today)) : -1;
}
} // namespace

int daysAgo(const QString &day, const QString &today)
{
    const QDate t = QDate::fromString(today, Qt::ISODate);
    return t.isValid() ? sinceToday(day, t) : -1;
}

QVariantMap week(const QVariantList &rows, const QString &todayText)
{
    const QDate today = QDate::fromString(todayText, Qt::ISODate);
    QVariantMap out;
    QVariantList days;
    if (!today.isValid()) {
        out.insert(key("days"), days);
        out.insert(key("total"), 0);
        out.insert(key("previous"), 0);
        out.insert(key("activeDays"), 0);
        return out;
    }
    int perDay[14] = {};
    for (const QVariant &v : rows) {
        const QVariantMap r = v.toMap();
        const int ago = sinceToday(r.value(key("day")).toString(), today);
        if (ago >= 0 && ago < 14)
            perDay[ago] += r.value(key("seconds")).toInt();
    }
    int total = 0;
    int previous = 0;
    int active = 0;
    for (int ago = 6; ago >= 0; --ago) {
        const QDate d = today.addDays(-ago);
        total += perDay[ago];
        if (perDay[ago] > 0)
            ++active;
        days.append(QVariantMap{{key("day"), d.toString(Qt::ISODate)},
                                {key("dow"), d.dayOfWeek()},
                                {key("seconds"), perDay[ago]},
                                {key("today"), ago == 0}});
    }
    for (int ago = 7; ago < 14; ++ago)
        previous += perDay[ago];
    out.insert(key("days"), days);
    out.insert(key("total"), total);
    out.insert(key("previous"), previous);
    out.insert(key("activeDays"), active);
    return out;
}

QVariantList top(const QVariantList &rows, const QString &todayText, int count)
{
    const QDate today = QDate::fromString(todayText, Qt::ISODate);
    struct Sum
    {
        int seconds = 0;
        int sessions = 0;
        qint64 last = 0;
    };
    QHash<QString, Sum> sums;
    for (const QVariant &v : rows) {
        const QVariantMap r = v.toMap();
        const int ago = sinceToday(r.value(key("day")).toString(), today);
        if (ago < 0 || ago >= TopWindowDays)
            continue;
        Sum &s = sums[r.value(key("appId")).toString()];
        s.seconds += r.value(key("seconds")).toInt();
        s.sessions += r.value(key("sessions")).toInt();
        s.last = qMax(s.last, r.value(key("last")).toLongLong());
    }
    QList<QString> apps = sums.keys();
    std::sort(apps.begin(), apps.end(), [&sums](const QString &a, const QString &b) {
        const Sum &x = sums[a];
        const Sum &y = sums[b];
        return x.seconds != y.seconds ? x.seconds > y.seconds : a < b;
    });
    QVariantList out;
    for (const QString &app : std::as_const(apps)) {
        const Sum &s = sums[app];
        if (s.seconds <= 0)
            continue;
        out.append(QVariantMap{{key("appId"), app}, {key("seconds"), s.seconds}, {key("sessions"), s.sessions},
                               {key("last"), s.last}});
        if (out.size() >= count)
            break;
    }
    return out;
}

QVariantList history(const QVariantList &sessions, int limit)
{
    QVariantList out;
    QString currentDay;
    int head = -1; // index of the heading of the day being listed
    int shown = 0;
    for (const QVariant &v : sessions) {
        if (shown >= limit)
            break;
        const QVariantMap s = v.toMap();
        const QString day = s.value(key("day")).toString();
        if (head < 0 || day != currentDay) {
            currentDay = day;
            head = int(out.size());
            out.append(QVariantMap{{key("kind"), QStringLiteral("day")}, {key("day"), day}, {key("seconds"), 0}});
        }
        // The day heading adds up the sessions listed under it.
        QVariantMap heading = out.at(head).toMap();
        heading[key("seconds")] = heading.value(key("seconds")).toInt() + s.value(key("seconds")).toInt();
        out[head] = heading;
        out.append(QVariantMap{{key("kind"), QStringLiteral("session")},
                               {key("appId"), s.value(key("appId"))},
                               {key("start"), s.value(key("start"))},
                               {key("seconds"), s.value(key("seconds"))},
                               {key("reason"), s.value(key("reason"))},
                               {key("open"), s.value(key("open"))}});
        ++shown;
    }
    return out;
}

QVariantMap highlights(const QVariantList &rows, const QString &todayText)
{
    const QDate today = QDate::fromString(todayText, Qt::ISODate);
    QVariantMap out;
    QVariantMap longest;
    QHash<QString, int> lastAgo; // app -> days since it was last played
    QHash<int, bool> playedOn;
    if (today.isValid()) {
        const QString month = today.toString(QStringLiteral("yyyy-MM"));
        for (const QVariant &v : rows) {
            const QVariantMap r = v.toMap();
            if (r.value(key("seconds")).toInt() <= 0)
                continue;
            const QString day = r.value(key("day")).toString();
            const int ago = sinceToday(day, today);
            if (ago < 0)
                continue;
            playedOn[ago] = true;
            const QString app = r.value(key("appId")).toString();
            if (!lastAgo.contains(app) || ago < lastAgo.value(app))
                lastAgo[app] = ago;
            if (day.startsWith(month) && r.value(key("longest")).toInt() > longest.value(key("seconds")).toInt())
                longest = QVariantMap{{key("appId"), app}, {key("seconds"), r.value(key("longest")).toInt()}};
        }
    }
    // A streak counts back from today, or from yesterday while today is still unplayed.
    int streak = 0;
    for (int ago = playedOn.value(0, false) ? 0 : 1;; ++ago) {
        if (!playedOn.value(ago, false))
            break;
        ++streak;
    }
    QVariantList lapsed;
    QList<QPair<int, QString>> old;
    for (auto it = lastAgo.cbegin(); it != lastAgo.cend(); ++it) {
        if (it.value() >= LapsedDays)
            old.append({it.value(), it.key()});
    }
    std::sort(old.begin(), old.end(), [](const QPair<int, QString> &a, const QPair<int, QString> &b) {
        return a.first != b.first ? a.first > b.first : a.second < b.second;
    });
    for (const auto &p : std::as_const(old)) {
        lapsed.append(QVariantMap{{key("appId"), p.second}, {key("days"), p.first}});
        if (lapsed.size() >= 3)
            break;
    }
    out.insert(key("longestMonth"), longest);
    out.insert(key("streak"), streak >= 2 ? streak : 0);
    out.insert(key("lapsed"), lapsed);
    return out;
}

QVariantMap game(const QVariantList &rows, const QString &appId, const QString &todayText)
{
    const QDate today = QDate::fromString(todayText, Qt::ISODate);
    int total = 0;
    int sessions = 0;
    int longest = 0;
    int playedDays = 0;
    qint64 first = 0;
    qint64 last = 0;
    QVariantList strip;
    for (int i = 0; i < 30; ++i)
        strip.append(0);
    for (const QVariant &v : rows) {
        const QVariantMap r = v.toMap();
        if (r.value(key("appId")).toString() != appId)
            continue;
        const int secs = r.value(key("seconds")).toInt();
        total += secs;
        sessions += r.value(key("sessions")).toInt();
        longest = qMax(longest, r.value(key("longest")).toInt());
        const qint64 f = r.value(key("first")).toLongLong();
        const qint64 l = r.value(key("last")).toLongLong();
        first = first == 0 ? f : qMin(first, f);
        last = qMax(last, l);
        if (secs > 0)
            ++playedDays;
        const int ago = today.isValid() ? sinceToday(r.value(key("day")).toString(), today) : -1;
        if (ago >= 0 && ago < 30)
            strip[29 - ago] = strip.at(29 - ago).toInt() + secs;
    }
    return QVariantMap{{key("total"), total},
                       {key("sessions"), sessions},
                       {key("first"), first},
                       {key("last"), last},
                       {key("longest"), longest},
                       {key("average"), sessions > 0 ? total / sessions : 0},
                       {key("strip"), strip},
                       {key("playedDays"), playedDays}};
}

} // namespace UsageStats
