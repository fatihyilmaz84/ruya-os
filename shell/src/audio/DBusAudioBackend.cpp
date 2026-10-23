#include "DBusAudioBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.Audio");
const QString PropertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

// a{su} -> channel name -> 0-100
QVariantMap parseChannels(const QDBusArgument &arg)
{
    QVariantMap out;
    arg.beginMap();
    while (!arg.atEnd()) {
        QString name;
        uint value = 0;
        arg.beginMapEntry();
        arg >> name >> value;
        arg.endMapEntry();
        out.insert(name, int(value));
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

// aa{sv}
QList<SinkInfo> parseSinks(const QDBusArgument &arg)
{
    QList<SinkInfo> out;
    arg.beginArray();
    while (!arg.atEnd()) {
        const QVariantMap dict = parseDict(arg);
        SinkInfo s;
        s.id = dict.value(QStringLiteral("id")).toString();
        s.name = dict.value(QStringLiteral("name")).toString();
        s.kind = dict.value(QStringLiteral("kind")).toString();
        s.isDefault = dict.value(QStringLiteral("is_default")).toBool();
        out.append(s);
    }
    arg.endArray();
    return out;
}

// The properties of the Audio interface as the shell wants them. Missing or malformed values
// fall back to silence-safe defaults (channels full, master 0, unmuted).
void parseState(const QVariantMap &props, int *volume, bool *muted, QVariantMap *channels)
{
    *volume = int(props.value(QStringLiteral("MasterVolume")).toUInt());
    *muted = props.value(QStringLiteral("Muted")).toBool();
    channels->clear();
    const QVariant raw = props.value(QStringLiteral("ChannelVolumes"));
    if (raw.canConvert<QDBusArgument>())
        *channels = parseChannels(raw.value<QDBusArgument>());
    for (const QString &name : AudioBackend::channelNames()) {
        if (!channels->contains(name))
            channels->insert(name, 100);
    }
}
} // namespace

DBusAudioBackend::DBusAudioBackend(QObject *parent)
    : AudioBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    m_bus.connect(Service, Path, Interface, QStringLiteral("SinksChanged"), this, SLOT(onSinksChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("DefaultSinkChanged"), this, SLOT(onSinksChanged()));
    m_bus.connect(Service, Path, PropertiesInterface, QStringLiteral("PropertiesChanged"), this,
                  SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
}

void DBusAudioBackend::refresh()
{
    refreshState();
    refreshSinks();
}

void DBusAudioBackend::refreshState()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("GetAll"));
    msg << Interface;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Audio GetAll failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        int volume = 0;
        bool muted = false;
        QVariantMap channels;
        parseState(parseDict(reply.arguments().constFirst().value<QDBusArgument>()), &volume, &muted, &channels);
        emit stateChanged(volume, muted, channels);
    });
}

void DBusAudioBackend::refreshSinks()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListSinks"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Audio ListSinks failed: %s", qPrintable(reply.errorMessage()));
            return;
        }
        emit sinksListed(parseSinks(reply.arguments().constFirst().value<QDBusArgument>()));
    });
}

// Properties.Set, then re-read: a Set that changes nothing sends no PropertiesChanged, but the
// backend contract says every command reports (the OSD shows at the ends of the scale).
void DBusAudioBackend::setProperty(const QString &name, const QVariant &value)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("Set"));
    msg << Interface << name << QVariant::fromValue(QDBusVariant(value));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, name](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<> reply = *w;
        if (reply.isError())
            qWarning("ruya-shell: Devices1.Audio set %s failed: %s", qPrintable(name),
                     qPrintable(reply.error().message()));
        refreshState();
    });
}

void DBusAudioBackend::setVolume(int volume)
{
    setProperty(QStringLiteral("MasterVolume"), QVariant::fromValue<uint>(uint(qBound(0, volume, 100))));
}

void DBusAudioBackend::setMuted(bool muted)
{
    setProperty(QStringLiteral("Muted"), muted);
}

void DBusAudioBackend::setChannelVolume(const QString &channel, int value)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SetChannelVolume"));
    msg << channel << uint(qBound(0, value, 100));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, channel](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid())
            qWarning("ruya-shell: Devices1.Audio SetChannelVolume %s failed: %s", qPrintable(channel),
                     qPrintable(reply.error().message()));
        else if (reply.value() != QLatin1String("ok"))
            qWarning("ruya-shell: Devices1.Audio SetChannelVolume %s: %s", qPrintable(channel),
                     qPrintable(reply.value()));
        refreshState();
    });
}

void DBusAudioBackend::setDefaultSink(const QString &id)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SetDefaultSink"));
    msg << id;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        // The new default arrives with DefaultSinkChanged.
        emit setDefaultSinkFinished(id, reply.isValid() ? reply.value() : QStringLiteral("failed"));
    });
}

void DBusAudioBackend::onSinksChanged()
{
    refreshSinks();
}

void DBusAudioBackend::onPropertiesChanged(const QString &interface, const QVariantMap &, const QStringList &)
{
    if (interface == Interface)
        refreshState();
}
