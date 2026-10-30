#include "DBusLibraryBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Library1");
const QString Path = QStringLiteral("/org/ruyaos/Library1");
const QString Interface = QStringLiteral("org.ruyaos.Library1");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

// a{ss}
QMap<QString, QString> parseArt(const QDBusArgument &arg)
{
    QMap<QString, QString> out;
    arg.beginMap();
    while (!arg.atEnd()) {
        QString key;
        QString value;
        arg.beginMapEntry();
        arg >> key >> value;
        arg.endMapEntry();
        out.insert(key, value);
    }
    arg.endMap();
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

LibraryItem toItem(const QVariantMap &d)
{
    LibraryItem i;
    i.id = d.value(QStringLiteral("id")).toString();
    i.kind = d.value(QStringLiteral("kind"), i.kind).toString();
    i.title = d.value(QStringLiteral("title")).toString();
    i.source = d.value(QStringLiteral("source")).toString();
    i.launch = d.value(QStringLiteral("launch")).toString();
    const QVariant art = d.value(QStringLiteral("art"));
    if (art.canConvert<QDBusArgument>())
        i.art = parseArt(art.value<QDBusArgument>());
    i.lastPlayed = d.value(QStringLiteral("last_played")).toLongLong();
    return i;
}
} // namespace

DBusLibraryBackend::DBusLibraryBackend(QObject *parent)
    : LibraryBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { listItems(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("ItemsChanged"), this, SIGNAL(itemsChanged()));
}

void DBusLibraryBackend::listItems()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListItems"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Library1 ListItems failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        QList<LibraryItem> items;
        const QDBusArgument arg = reply.arguments().constFirst().value<QDBusArgument>();
        arg.beginArray();
        while (!arg.atEnd())
            items.append(toItem(parseDict(arg)));
        arg.endArray();
        emit itemsListed(items);
    });
}

void DBusLibraryBackend::rescan()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Rescan"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        if (w->reply().type() != QDBusMessage::ReplyMessage)
            qWarning("ruya-shell: Library1 Rescan failed: %s", qPrintable(w->reply().errorMessage()));
        emit rescanFinished();
    });
}
