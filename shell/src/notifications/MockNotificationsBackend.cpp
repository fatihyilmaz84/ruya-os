#include "MockNotificationsBackend.h"

#include <QDateTime>
#include <QRegularExpression>
#include <QTimer>

#include <algorithm>

namespace {
const QStringList Sources = {QStringLiteral("system"), QStringLiteral("updates"), QStringLiteral("devices"),
                             QStringLiteral("store"), QStringLiteral("app")};
const QStringList Kinds = {QStringLiteral("info"), QStringLiteral("success"), QStringLiteral("warning"),
                           QStringLiteral("error")};
const QStringList Urgencies = {QStringLiteral("low"), QStringLiteral("normal"), QStringLiteral("critical")};

bool validClock(const QString &text)
{
    static const QRegularExpression re(QStringLiteral("^([01][0-9]|2[0-3]):[0-5][0-9]$"));
    return re.match(text).hasMatch();
}
} // namespace

MockNotificationsBackend::MockNotificationsBackend(QObject *parent)
    : NotificationsBackend(parent)
{
}

qint64 MockNotificationsBackend::now() const
{
    return m_now >= 0 ? m_now : QDateTime::currentMSecsSinceEpoch();
}

void MockNotificationsBackend::later(int delayMs, std::function<void()> fn)
{
    ++m_pending;
    QTimer::singleShot(delayMs, this, [this, fn] {
        --m_pending;
        fn();
    });
}

void MockNotificationsBackend::answer(const QString &op, uint id, const QString &status)
{
    later(0, [this, op, id, status] { emit finished(op, id, status); });
}

void MockNotificationsBackend::emitRemoved(const QString &profile, const QList<uint> &ids, const QString &reason)
{
    if (ids.isEmpty())
        return;
    later(0, [this, profile, ids, reason] { emit removed(profile, ids, reason); });
}

int MockNotificationsBackend::find(uint id, QString *profile) const
{
    for (auto it = m_lists.constBegin(); it != m_lists.constEnd(); ++it) {
        for (int i = 0; i < it.value().size(); ++i) {
            if (it.value().at(i).item.id == id) {
                if (profile)
                    *profile = it.key();
                return i;
            }
        }
    }
    return -1;
}

QList<NotificationItem> MockNotificationsBackend::sorted(const QString &profile) const
{
    QList<NotificationItem> out;
    for (const Entry &e : m_lists.value(profile))
        out.append(e.item);
    // Pinned first, then newest first (by time, then by id), as the contract says.
    std::stable_sort(out.begin(), out.end(), [](const NotificationItem &a, const NotificationItem &b) {
        if (a.pinned != b.pinned)
            return a.pinned;
        if (a.time != b.time)
            return a.time > b.time;
        return a.id > b.id;
    });
    return out;
}

void MockNotificationsBackend::applyCaps(const QString &profile)
{
    if (!m_lists.contains(profile))
        return;
    QList<Entry> &list = m_lists[profile];
    QList<uint> dropped;
    const qint64 oldest = now() - MaxAgeMs;
    for (int i = list.size() - 1; i >= 0; --i) {
        if (!list.at(i).item.pinned && list.at(i).item.time < oldest) {
            dropped.append(list.at(i).item.id);
            list.removeAt(i);
        }
    }
    // Past 50: the oldest unpinned ones go (the list is kept in posting order, oldest first).
    while (list.size() > MaxItems) {
        int victim = -1;
        for (int i = 0; i < list.size(); ++i) {
            if (list.at(i).item.pinned)
                continue;
            if (victim < 0 || list.at(i).item.time < list.at(victim).item.time)
                victim = i;
        }
        if (victim < 0)
            break;                      // only pinned items left: they are never dropped
        dropped.append(list.at(victim).item.id);
        list.removeAt(victim);
    }
    emitRemoved(profile, dropped, QStringLiteral("expired"));
}

void MockNotificationsBackend::refresh(const QString &profile)
{
    ++m_calls[QStringLiteral("list")];
    applyCaps(profile);
    const quint64 request = beginItemsRequest();
    const QList<NotificationItem> items = sorted(profile);   // the list as it is now, even if the reply is late
    later(m_delay, [this, request, profile, items] { deliverItems(request, profile, items); });
}

void MockNotificationsBackend::refreshSettings()
{
    publishSettings();
}

void MockNotificationsBackend::publishSettings()
{
    const quint64 request = beginSettingsRequest();
    const NotificationSettings settings = m_settings.value(m_profile);
    later(0, [this, request, settings] { deliverSettings(request, settings); });
}

void MockNotificationsBackend::selectProfile(const QString &profile)
{
    m_profile = profile;
    publishSettings();
}

void MockNotificationsBackend::dismiss(uint id)
{
    ++m_calls[QStringLiteral("dismiss")];
    QString profile;
    const int at = find(id, &profile);
    if (at < 0) {
        answer(QStringLiteral("dismiss"), id, QStringLiteral("unknown"));
        return;
    }
    if (m_lists[profile].at(at).item.pinned) {
        answer(QStringLiteral("dismiss"), id, QStringLiteral("pinned"));
        return;
    }
    m_lists[profile].removeAt(at);
    emitRemoved(profile, {id}, QStringLiteral("dismissed"));
    answer(QStringLiteral("dismiss"), id, QStringLiteral("ok"));
}

void MockNotificationsBackend::dismissAll(const QString &profile)
{
    ++m_calls[QStringLiteral("dismissall")];
    QList<uint> dropped;
    QList<Entry> &list = m_lists[profile];
    for (int i = list.size() - 1; i >= 0; --i) {
        if (!list.at(i).item.pinned) {
            dropped.append(list.at(i).item.id);
            list.removeAt(i);
        }
    }
    emitRemoved(profile, dropped, QStringLiteral("cleared"));
    answer(QStringLiteral("dismissall"), 0, QStringLiteral("ok"));
}

void MockNotificationsBackend::invoke(uint id, const QString &action)
{
    ++m_calls[QStringLiteral("invoke")];
    QString profile;
    const int at = find(id, &profile);
    if (at < 0) {
        answer(QStringLiteral("invoke"), id, QStringLiteral("unknown"));
        return;
    }
    const NotificationItem &item = m_lists[profile].at(at).item;
    const bool offered = std::any_of(item.actions.cbegin(), item.actions.cend(),
                                     [&action](const NotificationAction &a) { return a.id == action; });
    if (!offered) {
        answer(QStringLiteral("invoke"), id, QStringLiteral("invalid"));
        return;
    }
    if (!item.pinned) {             // a pinned item stays until its source withdraws it
        m_lists[profile].removeAt(at);
        emitRemoved(profile, {id}, QStringLiteral("invoked"));
    }
    answer(QStringLiteral("invoke"), id, QStringLiteral("ok"));
}

void MockNotificationsBackend::markRead(const QString &profile)
{
    ++m_calls[QStringLiteral("markread")];
    bool any = false;
    for (Entry &e : m_lists[profile]) {
        if (e.item.unread) {
            e.item.unread = false;
            any = true;
        }
    }
    if (any)
        later(0, [this, profile] { emit changed(profile); });
    answer(QStringLiteral("markread"), 0, QStringLiteral("ok"));
}

void MockNotificationsBackend::post(const QString &profile, const QString &key, const NotificationItem &item)
{
    ++m_calls[QStringLiteral("post")];
    const bool valid = !profile.isEmpty() && !item.title.trimmed().isEmpty() && Sources.contains(item.source)
                       && Kinds.contains(item.kind) && Urgencies.contains(item.urgency) && item.actions.size() <= 2;
    if (!valid) {
        later(0, [this, key] { emit posted(key, QStringLiteral("invalid"), 0); });
        return;
    }
    QList<Entry> &list = m_lists[profile];
    if (!key.isEmpty()) {           // one item per key: the new one replaces the earlier one
        for (int i = 0; i < list.size(); ++i) {
            if (list.at(i).key == key) {
                const uint old = list.at(i).item.id;
                list.removeAt(i);
                emitRemoved(profile, {old}, QStringLiteral("replaced"));
                break;
            }
        }
    }
    NotificationItem stored = item;
    stored.id = m_nextId++;
    stored.unread = true;
    stored.time = now();
    list.append({stored, key});
    applyCaps(profile);
    later(0, [this, profile, stored] { emit added(profile, stored); });
    const uint id = stored.id;
    later(0, [this, key, id] { emit posted(key, QStringLiteral("ok"), id); });
}

void MockNotificationsBackend::withdraw(const QString &key)
{
    ++m_calls[QStringLiteral("withdraw")];
    if (!key.isEmpty()) {
        for (auto it = m_lists.begin(); it != m_lists.end(); ++it) {
            for (int i = it.value().size() - 1; i >= 0; --i) {
                if (it.value().at(i).key == key) {
                    const uint id = it.value().at(i).item.id;
                    it.value().removeAt(i);
                    emitRemoved(it.key(), {id}, QStringLiteral("withdrawn"));
                }
            }
        }
    }
    answer(QStringLiteral("withdraw"), 0, key.isEmpty() ? QStringLiteral("invalid") : QStringLiteral("ok"));
}

void MockNotificationsBackend::setSetting(const QString &name, const QVariant &value)
{
    ++m_calls[QStringLiteral("set")];
    NotificationSettings s = m_settings.value(m_profile);
    bool ok = true;
    if (name == QLatin1String("Quiet")) {
        s.quiet = value.toBool();
    } else if (name == QLatin1String("DontInterruptGames")) {
        s.dontInterruptGames = value.toBool();
    } else if (name == QLatin1String("Sounds")) {
        s.sounds = value.toBool();
    } else if (name == QLatin1String("ToastSeconds")) {
        const uint secs = value.toUInt(&ok);
        ok = ok && secs >= 2 && secs <= 15;
        if (ok)
            s.toastSeconds = secs;
    } else if (name == QLatin1String("QuietHours")) {
        const QVariantMap m = value.toMap();
        const QString from = m.value(QStringLiteral("from")).toString();
        const QString to = m.value(QStringLiteral("to")).toString();
        ok = validClock(from) && validClock(to);
        if (ok) {
            s.quietHoursEnabled = m.value(QStringLiteral("enabled")).toBool();
            s.quietFrom = from;
            s.quietTo = to;
        }
    } else if (name == QLatin1String("SourcesEnabled")) {
        const QVariantMap m = value.toMap();
        QVariantMap clean;
        for (auto it = m.constBegin(); it != m.constEnd(); ++it)
            clean.insert(it.key(), it.value().toBool());
        s.sourcesEnabled = clean;
    } else {
        ok = false;
    }
    if (ok) {
        m_settings.insert(m_profile, s);
        publishSettings();
    }
    const QString status = ok ? QStringLiteral("ok") : QStringLiteral("invalid");
    later(0, [this, name, status] { emit settingFinished(name, status); });
}

void MockNotificationsBackend::appNotify(const QString &profile, const NotificationItem &item)
{
    NotificationItem fromApp = item;
    fromApp.source = QStringLiteral("app");
    post(profile, QString(), fromApp);
    --m_calls[QStringLiteral("post")];      // the bridge, not the shell, posted it
}

void MockNotificationsBackend::reset()
{
    m_lists.clear();
    m_settings.clear();
    m_now = -1;
    m_delay = 0;
    m_calls.clear();
    publishSettings();
}
