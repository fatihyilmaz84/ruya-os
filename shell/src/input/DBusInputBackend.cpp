#include "DBusInputBackend.h"

#include <QDBusArgument>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Input1");
const QString Path = QStringLiteral("/org/ruyaos/Input1");
const QString Interface = QStringLiteral("org.ruyaos.Input1");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
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

// One device record with the keys and types of api/dbus/org.ruyaos.Input1.xml (a missing key is
// its empty value, so an older or newer service still gives a whole record).
QVariantMap recordOf(const QVariantMap &d)
{
    return {
        {QStringLiteral("id"), d.value(QStringLiteral("id")).toString()},
        {QStringLiteral("instance"), d.value(QStringLiteral("instance")).toString()},
        {QStringLiteral("name"), d.value(QStringLiteral("name")).toString()},
        {QStringLiteral("family"), d.value(QStringLiteral("family")).toString()},
        {QStringLiteral("connection"), d.value(QStringLiteral("connection")).toString()},
        {QStringLiteral("battery"), d.contains(QStringLiteral("battery")) ? d.value(QStringLiteral("battery")).toInt() : -1},
        {QStringLiteral("charging"), d.value(QStringLiteral("charging")).toBool()},
        {QStringLiteral("slot"), d.value(QStringLiteral("slot")).toUInt()},
        {QStringLiteral("profile"), d.value(QStringLiteral("profile")).toString()},
        {QStringLiteral("routed"), d.value(QStringLiteral("routed")).toBool()},
    };
}
} // namespace

DBusInputBackend::DBusInputBackend(QObject *parent)
    : InputBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForOwnerChange, this)
{
    // An owner change straight from one owner to the next (no gap) is a new service too.
    connect(&m_watcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &, const QString &newOwner) {
                m_ownerSeen = true;
                setServiceOwned(!newOwner.isEmpty());
                if (!newOwner.isEmpty())
                    emit serviceAppeared();
            });
    // The device signals only say that the list changed: it is asked again (records are small).
    m_bus.connect(Service, Path, Interface, QStringLiteral("DeviceAdded"), this, SLOT(onDevicesChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("DeviceChanged"), this, SLOT(onDevicesChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("DeviceRemoved"), this, SLOT(onDevicesChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("TestInput"), this,
                  SLOT(onTestInput(QString, QString, int, QString)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("TestEnded"), this, SLOT(onTestEnded(QString, QString)));
    // Who owns the name now, asked without blocking; a change that arrives first wins.
    if (auto *busInterface = m_bus.interface()) {
        auto *asked = new QDBusPendingCallWatcher(busInterface->asyncCall(QStringLiteral("NameHasOwner"), Service), this);
        connect(asked, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<bool> reply = *w;
            if (reply.isValid() && !m_ownerSeen)
                setServiceOwned(reply.value());
        });
    }
}

void DBusInputBackend::setRoute(const QString &route, const QString &instance, const QString &appId,
                                const QString &profile)
{
    const quint64 request = beginRoute();
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("SetRoute"));
    msg << route << instance << appId << profile;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request, route](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Input1 SetRoute %s failed: %s", qPrintable(route), qPrintable(reply.error().message()));
            deliverRoute(request, QStringLiteral("failed"));
            return;
        }
        deliverRoute(request, reply.argumentAt<0>());
    });
}

void DBusInputBackend::refreshDevices()
{
    const quint64 request = beginDevicesRequest();
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("ListDevices"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, request](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Input1 ListDevices failed: %s", qPrintable(reply.errorMessage()));
            deliverDevices(request, false, {});
            return;
        }
        QVariantList list;
        const QDBusArgument arg = reply.arguments().at(0).value<QDBusArgument>();
        arg.beginArray();
        while (!arg.atEnd())
            list.append(recordOf(parseDict(arg)));
        arg.endArray();
        deliverDevices(request, true, list);
    });
}

void DBusInputBackend::getCapabilities(const QString &deviceId)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetCapabilities"));
    msg << deviceId;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, deviceId](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() < 2) {
            qWarning("ruya-shell: Input1 GetCapabilities failed: %s", qPrintable(reply.errorMessage()));
            emit capabilitiesFinished(deviceId, QStringLiteral("failed"), {});
            return;
        }
        QVariantList caps;
        const QDBusArgument arg = reply.arguments().at(1).value<QDBusArgument>();
        arg.beginArray();
        while (!arg.atEnd()) {
            QString name;
            bool hardware = false, driver = false, available = false, output = false;
            arg.beginStructure();
            arg >> name >> hardware >> driver >> available >> output;
            arg.endStructure();
            caps.append(QVariantMap{{QStringLiteral("name"), name}, {QStringLiteral("hardware"), hardware},
                                    {QStringLiteral("driver"), driver}, {QStringLiteral("available"), available},
                                    {QStringLiteral("output"), output}});
        }
        arg.endArray();
        emit capabilitiesFinished(deviceId, reply.arguments().at(0).toString(), caps);
    });
}

void DBusInputBackend::startTest(const QString &deviceId)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("StartTest"));
    msg << deviceId;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, deviceId](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid()) {
            qWarning("ruya-shell: Input1 StartTest failed: %s", qPrintable(reply.error().message()));
            emit testStartFinished(deviceId, QStringLiteral("failed"));
            return;
        }
        emit testStartFinished(deviceId, reply.argumentAt<0>());
    });
}

void DBusInputBackend::stopTest(const QString &deviceId)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("StopTest"));
    msg << deviceId;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> reply = *w;
        if (!reply.isValid())
            qWarning("ruya-shell: Input1 StopTest failed: %s", qPrintable(reply.error().message()));
    });
}

void DBusInputBackend::onDevicesChanged()
{
    emit devicesChanged();
}

void DBusInputBackend::onTestInput(const QString &deviceId, const QString &input, int value, const QString &source)
{
    emit testInput(deviceId, input, value, source);
}

void DBusInputBackend::onTestEnded(const QString &deviceId, const QString &reason)
{
    emit testEnded(deviceId, reason);
}
