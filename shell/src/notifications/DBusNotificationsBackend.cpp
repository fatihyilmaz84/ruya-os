#include "DBusNotificationsBackend.h"

#include <QDBusArgument>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

// The two structs the shell sends: an action (ss) of Post and the (bss) of QuietHours. Received
// structs are read by hand (parseItem), so only these need a registered type.
struct RuyaNotifyAction
{
    QString id;
    QString label;
};
Q_DECLARE_METATYPE(RuyaNotifyAction)

QDBusArgument &operator<<(QDBusArgument &arg, const RuyaNotifyAction &a)
{
    arg.beginStructure();
    arg << a.id << a.label;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, RuyaNotifyAction &a)
{
    arg.beginStructure();
    arg >> a.id >> a.label;
    arg.endStructure();
    return arg;
}

struct RuyaQuietHours
{
    bool enabled = false;
    QString from;
    QString to;
};
Q_DECLARE_METATYPE(RuyaQuietHours)

QDBusArgument &operator<<(QDBusArgument &arg, const RuyaQuietHours &q)
{
    arg.beginStructure();
    arg << q.enabled << q.from << q.to;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, RuyaQuietHours &q)
{
    arg.beginStructure();
    arg >> q.enabled >> q.from >> q.to;
    arg.endStructure();
    return arg;
}

using RuyaSourceSwitches = QMap<QString, bool>;

namespace {
const QString Service = QStringLiteral("org.ruyaos.Notifications1");
const QString Path = QStringLiteral("/org/ruyaos/Notifications1");
const QString Interface = QStringLiteral("org.ruyaos.Notifications1");
const QString PropertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

// (ussssssa(ss)sbbx), field order as in the XML.
NotificationItem parseItem(const QDBusArgument &arg)
{
    NotificationItem it;
    qlonglong time = 0;
    arg.beginStructure();
    arg >> it.id >> it.source >> it.appId >> it.kind >> it.title >> it.body >> it.icon;
    arg.beginArray();
    while (!arg.atEnd()) {
        NotificationAction a;
        arg.beginStructure();
        arg >> a.id >> a.label;
        arg.endStructure();
        it.actions.append(a);
    }
    arg.endArray();
    arg >> it.urgency >> it.pinned >> it.unread >> time;
    arg.endStructure();
    it.time = time;
    return it;
}

QList<NotificationItem> parseItems(const QDBusArgument &arg)
{
    QList<NotificationItem> out;
    arg.beginArray();
    while (!arg.atEnd())
        out.append(parseItem(arg));
    arg.endArray();
    return out;
}

// a{sv}
QVariantMap parseDict(const QDBusArgument &arg)
{
    QVariantMap out;
    arg.beginMap();
    while (!arg.atEnd()) {
        QString key;
        QDBusVariant value;
        arg.beginMapEntry();
        arg >> key >> value;
        arg.endMapEntry();
        out.insert(key, value.variant());
    }
    arg.endMap();
    return out;
}

// Applies the properties present in `props` to `s` (GetAll and PropertiesChanged both).
void applyProps(const QVariantMap &props, NotificationSettings &s)
{
    if (props.contains(QStringLiteral("Quiet")))
        s.quiet = props.value(QStringLiteral("Quiet")).toBool();
    if (props.contains(QStringLiteral("DontInterruptGames")))
        s.dontInterruptGames = props.value(QStringLiteral("DontInterruptGames")).toBool();
    if (props.contains(QStringLiteral("Sounds")))
        s.sounds = props.value(QStringLiteral("Sounds")).toBool();
    if (props.contains(QStringLiteral("ToastSeconds")))
        s.toastSeconds = props.value(QStringLiteral("ToastSeconds")).toUInt();
    const QVariant hours = props.value(QStringLiteral("QuietHours"));
    if (hours.canConvert<QDBusArgument>()) {
        RuyaQuietHours q;
        hours.value<QDBusArgument>() >> q;
        s.quietHoursEnabled = q.enabled;
        s.quietFrom = q.from;
        s.quietTo = q.to;
    }
    const QVariant sources = props.value(QStringLiteral("SourcesEnabled"));
    if (sources.canConvert<QDBusArgument>()) {
        const QDBusArgument arg = sources.value<QDBusArgument>();
        QVariantMap out;
        arg.beginMap();
        while (!arg.atEnd()) {
            QString key;
            bool on = true;
            arg.beginMapEntry();
            arg >> key >> on;
            arg.endMapEntry();
            out.insert(key, on);
        }
        arg.endMap();
        s.sourcesEnabled = out;
    }
}
} // namespace

DBusNotificationsBackend::DBusNotificationsBackend(QObject *parent)
    : NotificationsBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForOwnerChange, this)
{
    qDBusRegisterMetaType<RuyaNotifyAction>();
    qDBusRegisterMetaType<QList<RuyaNotifyAction>>();
    qDBusRegisterMetaType<RuyaQuietHours>();
    qDBusRegisterMetaType<RuyaSourceSwitches>();
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { serviceUp(); });
    connect(&m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this] { m_up = false; });
    // Is it there already? Asked without blocking.
    auto ask = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"),
                                              QStringLiteral("org.freedesktop.DBus"), QStringLiteral("NameHasOwner"));
    ask << Service;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(ask), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<bool> reply = *w;
        m_known = true;
        if (reply.isValid() && reply.value())
            serviceUp();
    });
    m_bus.connect(Service, Path, Interface, QStringLiteral("Added"), this, SLOT(onAdded(QDBusMessage)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("Removed"), this, SLOT(onRemoved(QDBusMessage)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("Changed"), this, SLOT(onChanged(QString)));
    m_bus.connect(Service, Path, PropertiesInterface, QStringLiteral("PropertiesChanged"), this,
                  SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
}

void DBusNotificationsBackend::serviceUp()
{
    if (m_up)
        return;
    m_up = true;
    m_known = true;
    refreshSettings();
    emit changed(QString());     // the facade lists again
}

bool DBusNotificationsBackend::available()
{
    if (m_up)
        return true;
    if (m_known && !m_toldAbsent) {
        m_toldAbsent = true;
        qWarning("ruya-shell: Notifications1 is not on the bus: notifications are shown but not kept");
    }
    return false;
}

void DBusNotificationsBackend::refresh(const QString &profile)
{
    if (!available())
        return;
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("List"));
    msg << profile;
    const quint64 request = beginItemsRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request, profile](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Notifications1 List failed: %s", qPrintable(reply.errorMessage()));
            failItems(request);
            return;
        }
        deliverItems(request, profile, parseItems(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

void DBusNotificationsBackend::refreshSettings()
{
    if (!available())
        return;
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("GetAll"));
    msg << Interface;
    const quint64 request = beginSettingsRequest();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Notifications1 GetAll failed: %s", qPrintable(reply.errorMessage()));
            failSettings(request);
            return;
        }
        NotificationSettings s;
        applyProps(parseDict(reply.arguments().constFirst().value<QDBusArgument>()), s);
        deliverSettings(request, s);
    });
}

void DBusNotificationsBackend::selectProfile(const QString &)
{
    refreshSettings();      // the service follows Profiles1's active profile: read its settings
}

void DBusNotificationsBackend::call(const QString &method, const QString &op, uint id, const QVariantList &args)
{
    if (!available())
        return;
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, method, op, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid())
            qWarning("ruya-shell: Notifications1 %s failed: %s", qPrintable(method), qPrintable(reply.error().message()));
        emit finished(op, id, reply.isValid() ? reply.value() : QStringLiteral("failed"));
    });
}

void DBusNotificationsBackend::dismiss(uint id)
{
    call(QStringLiteral("Dismiss"), QStringLiteral("dismiss"), id, {QVariant::fromValue(id)});
}

void DBusNotificationsBackend::dismissAll(const QString &profile)
{
    call(QStringLiteral("DismissAll"), QStringLiteral("dismissall"), 0, {profile});
}

void DBusNotificationsBackend::invoke(uint id, const QString &action)
{
    call(QStringLiteral("Invoke"), QStringLiteral("invoke"), id, {QVariant::fromValue(id), action});
}

void DBusNotificationsBackend::markRead(const QString &profile)
{
    call(QStringLiteral("MarkRead"), QStringLiteral("markread"), 0, {profile});
}

void DBusNotificationsBackend::withdraw(const QString &key)
{
    call(QStringLiteral("Withdraw"), QStringLiteral("withdraw"), 0, {key});
}

void DBusNotificationsBackend::post(const QString &profile, const QString &key, const NotificationItem &item)
{
    if (!available())
        return;
    QList<RuyaNotifyAction> actions;
    for (const NotificationAction &a : item.actions)
        actions.append({a.id, a.label});
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Post"));
    msg << profile << key << item.source << item.appId << item.kind << item.title << item.body << item.icon
        << QVariant::fromValue(actions) << item.urgency << item.pinned;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, key](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString, uint> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Notifications1 Post failed: %s", qPrintable(reply.error().message()));
            emit posted(key, QStringLiteral("failed"), 0);
            return;
        }
        emit posted(key, reply.argumentAt<0>(), reply.argumentAt<1>());
    });
}

void DBusNotificationsBackend::setSetting(const QString &name, const QVariant &value)
{
    if (!available()) {
        emit settingFinished(name, QStringLiteral("failed"));
        return;
    }
    QVariant wire = value;
    if (name == QLatin1String("QuietHours")) {
        const QVariantMap m = value.toMap();
        wire = QVariant::fromValue(RuyaQuietHours{m.value(QStringLiteral("enabled")).toBool(),
                                                  m.value(QStringLiteral("from")).toString(),
                                                  m.value(QStringLiteral("to")).toString()});
    } else if (name == QLatin1String("SourcesEnabled")) {
        RuyaSourceSwitches map;
        const QVariantMap m = value.toMap();
        for (auto it = m.constBegin(); it != m.constEnd(); ++it)
            map.insert(it.key(), it.value().toBool());
        wire = QVariant::fromValue(map);
    } else if (name == QLatin1String("ToastSeconds")) {
        wire = QVariant::fromValue(value.toUInt());
    } else {
        wire = QVariant::fromValue(value.toBool());
    }
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("Set"));
    msg << Interface << name << QVariant::fromValue(QDBusVariant(wire));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, name](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        const bool ok = reply.type() == QDBusMessage::ReplyMessage;
        if (!ok)
            qWarning("ruya-shell: Notifications1 Set %s failed: %s", qPrintable(name), qPrintable(reply.errorMessage()));
        emit settingFinished(name, ok ? QStringLiteral("ok") : QStringLiteral("failed"));
        refreshSettings();
    });
}

void DBusNotificationsBackend::onAdded(const QDBusMessage &message)
{
    const QVariantList args = message.arguments();
    if (args.size() < 2)
        return;
    emit added(args.at(0).toString(), parseItem(args.at(1).value<QDBusArgument>()));
}

void DBusNotificationsBackend::onRemoved(const QDBusMessage &message)
{
    const QVariantList args = message.arguments();
    if (args.size() < 3)
        return;
    QList<uint> ids;
    const QVariant raw = args.at(1);
    if (raw.canConvert<QDBusArgument>()) {
        const QDBusArgument arg = raw.value<QDBusArgument>();
        arg.beginArray();
        while (!arg.atEnd()) {
            uint id = 0;
            arg >> id;
            ids.append(id);
        }
        arg.endArray();
    } else if (raw.metaType() == QMetaType::fromType<QList<uint>>()) {
        ids = raw.value<QList<uint>>();
    } else {
        for (const QVariant &v : raw.toList())
            ids.append(v.toUInt());
    }
    emit removed(args.at(0).toString(), ids, args.at(2).toString());
}

void DBusNotificationsBackend::onChanged(const QString &profile)
{
    emit changed(profile);
}

void DBusNotificationsBackend::onPropertiesChanged(const QString &interface, const QVariantMap &, const QStringList &)
{
    if (interface == Interface)
        refreshSettings();
}
