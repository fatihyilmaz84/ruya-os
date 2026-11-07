#include "DBusDisplayBackend.h"

#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QStringList>

#include <memory>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Devices1");
const QString Path = QStringLiteral("/org/ruyaos/Devices1");
const QString Interface = QStringLiteral("org.ruyaos.Devices1.Display");
const QString Properties = QStringLiteral("org.freedesktop.DBus.Properties");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

// The contract's snake_case keys as the shell's QML names them.
QString camel(const QString &key)
{
    if (key == QLatin1String("width_mm"))
        return QStringLiteral("widthMm");
    if (key == QLatin1String("height_mm"))
        return QStringLiteral("heightMm");
    if (key == QLatin1String("refresh_mhz"))
        return QStringLiteral("refreshMhz");
    return key;
}

QVariantList parseRows(const QDBusArgument &arg);

// a{sv}; a "modes" value (aa{sv}) is parsed into a list of maps.
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
        QVariant v = value.variant();
        if (v.canConvert<QDBusArgument>())
            v = parseRows(v.value<QDBusArgument>());
        out.insert(camel(key), v);
    }
    arg.endMap();
    return out;
}

// aa{sv}
QVariantList parseRows(const QDBusArgument &arg)
{
    QVariantList out;
    arg.beginArray();
    while (!arg.atEnd())
        out.append(parseDict(arg));
    arg.endArray();
    return out;
}
} // namespace

DBusDisplayBackend::DBusDisplayBackend(QObject *parent)
    : DisplayBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { refresh(); });
    // UiScale changes as a property.
    m_bus.connect(Service, Path, Properties, QStringLiteral("PropertiesChanged"), this,
                  SLOT(onPropertiesChanged(QString,QVariantMap,QStringList)));
}

void DBusDisplayBackend::onPropertiesChanged(const QString &interface, const QVariantMap &, const QStringList &)
{
    if (interface == Interface)
        refresh();
}

void DBusDisplayBackend::refresh()
{
    // Three questions, one snapshot. A failure at any step is an outcome too: an older snapshot
    // arriving after it is stale.
    const quint64 request = beginStateRequest();
    auto list = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListOutputs"));
    auto *outputsCall = new QDBusPendingCallWatcher(m_bus.asyncCall(list), this);
    connect(outputsCall, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Devices1.Display ListOutputs failed: %s", qPrintable(reply.errorMessage()));
            acceptState(request);
            return;
        }
        const QVariantList outputs = parseRows(reply.arguments().constFirst().value<QDBusArgument>());
        auto get = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetPending"));
        auto *pendingCall = new QDBusPendingCallWatcher(m_bus.asyncCall(get), this);
        connect(pendingCall, &QDBusPendingCallWatcher::finished, this,
                [this, request, outputs](QDBusPendingCallWatcher *p) {
                    p->deleteLater();
                    const QDBusMessage reply = p->reply();
                    const QVariantMap pending = reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()
                        ? QVariantMap()
                        : parseDict(reply.arguments().constFirst().value<QDBusArgument>());
                    auto prop = QDBusMessage::createMethodCall(Service, Path, Properties, QStringLiteral("Get"));
                    prop.setArguments({Interface, QStringLiteral("UiScale")});
                    auto *scaleCall = new QDBusPendingCallWatcher(m_bus.asyncCall(prop), this);
                    connect(scaleCall, &QDBusPendingCallWatcher::finished, this,
                            [this, request, outputs, pending](QDBusPendingCallWatcher *s) {
                                s->deleteLater();
                                const QDBusPendingReply<QDBusVariant> value = *s;
                                // A scale we cannot ask about is Auto, not an error.
                                const int scale = value.isValid() ? value.value().variant().toInt() : 0;
                                deliverState(request, outputs, pending, scale);
                            });
                });
    });
}

void DBusDisplayBackend::callStatus(const QString &method, const QVariantList &args,
                                    void (DisplayBackend::*done)(const QString &))
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, method, done](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid())
            qWarning("ruya-shell: Devices1.Display %s failed: %s", qPrintable(method), qPrintable(reply.error().message()));
        (this->*done)(reply.isValid() ? reply.value() : QStringLiteral("failed"));
        refresh();
    });
}

void DBusDisplayBackend::setMode(const QString &output, uint width, uint height, uint refreshMhz)
{
    callStatus(QStringLiteral("SetMode"), {output, width, height, refreshMhz}, &DisplayBackend::setModeFinished);
}

void DBusDisplayBackend::keep()
{
    callStatus(QStringLiteral("Keep"), {}, &DisplayBackend::keepFinished);
}

void DBusDisplayBackend::revert()
{
    callStatus(QStringLiteral("Revert"), {}, &DisplayBackend::revertFinished);
}

void DBusDisplayBackend::setUiScale(int percent)
{
    callStatus(QStringLiteral("SetUiScale"), {static_cast<uint>(percent)}, &DisplayBackend::setUiScaleFinished);
}

void DBusDisplayBackend::takeFallbackNotice()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("TakeFallbackNotice"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<bool> reply = *w;
        emit fallbackNoticeReported(reply.isValid() && reply.value());
    });
}

void DBusDisplayBackend::restartShell()
{
    // The shell is the compositor: ending the process makes the unit start it again
    // (ruya-compositor@.service has Restart=always), and its ExecStartPre= runs the guard first.
    qInfo("ruya-shell: display: restarting to apply the screen mode");
    QCoreApplication::exit(0);
}
