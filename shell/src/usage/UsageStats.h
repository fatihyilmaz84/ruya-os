#pragma once

#include <QString>
#include <QVariantList>
#include <QVariantMap>

// What the Activity pages show, computed from the ledger's day rows and sessions (T-247). Pure
// functions of their arguments (`today` is "YYYY-MM-DD" in the device time zone, from the
// service), so a test gives them any date. Nothing here is translated: the pages turn these
// numbers into words.
namespace UsageStats {

// The last seven days ending today, oldest first:
//   { days: [{ day, dow (1 = Monday .. 7 = Sunday), seconds, today }], total, previous, activeDays }
// `previous` is the seven days before them.
QVariantMap week(const QVariantList &rows, const QString &today);

// The most played apps of the last 30 days, most first (at most `count`):
//   [{ appId, seconds, sessions, last (unix s) }]
QVariantList top(const QVariantList &rows, const QString &today, int count = 5);

// The sessions newest first, grouped by day, as one flat list:
//   { kind: "day", day, seconds }  then  { kind: "session", appId, start, seconds, reason, open }
QVariantList history(const QVariantList &sessions, int limit = 60);

// Modest highlights: { longestMonth: { appId, seconds } or {}, streak (days in a row, 0 if under
// two), lapsed: [{ appId, days }] (apps not played for 60 days or more, longest first, at most 3) }
QVariantMap highlights(const QVariantList &rows, const QString &today);

// One app: { total, sessions, first, last, longest, average, strip: [30 seconds values, oldest
// first, the last is today], playedDays }. `total` is 0 for an app never played.
QVariantMap game(const QVariantList &rows, const QString &appId, const QString &today);

// How many days ago `day` was (0 = today); -1 for a bad date.
int daysAgo(const QString &day, const QString &today);

} // namespace UsageStats
