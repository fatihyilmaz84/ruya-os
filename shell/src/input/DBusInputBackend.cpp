#include "DBusInputBackend.h"

#include "InputProfileCalls.h"

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

// One profile summary of ListProfiles with the keys and types of the XML (a missing key is its
// empty value).
QVariantMap summaryOf(const QVariantMap &d)
{
    QVariantMap out;
    for (const char *key : {"id", "name", "scope", "scope_id", "inherits", "match_family", "match_device", "layout"})
        out.insert(QLatin1String(key), d.value(QLatin1String(key)).toString());
    for (const char *key : {"builtin", "assigned", "left_stick_changed", "right_stick_changed", "changed"})
        out.insert(QLatin1String(key), d.value(QLatin1String(key)).toBool());
    out.insert(QStringLiteral("remapped"), d.value(QStringLiteral("remapped")).toUInt());
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
        {QStringLiteral("layout"), d.value(QStringLiteral("layout")).toString()},
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
    m_bus.connect(Service, Path, Interface, QStringLiteral("ProfilesChanged"), this, SLOT(onProfilesChanged(QString)));
    m_bus.connect(Service, Path, QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("PropertiesChanged"),
                  this, SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
    m_bus.connect(Service, Path, Interface, QStringLiteral("ActiveInputChanged"), this,
                  SLOT(onActiveInputChanged(QString, QString)));
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

void DBusInputBackend::startTest(const QString &deviceId, bool holdLeftStick)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("StartTest"));
    msg << deviceId << holdLeftStick;
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

void DBusInputBackend::readConfirmButton()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, QStringLiteral("org.freedesktop.DBus.Properties"),
                                              QStringLiteral("Get"));
    msg << Interface << QStringLiteral("ConfirmButton");
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            qWarning("ruya-shell: Input1 ConfirmButton failed: %s", qPrintable(reply.errorMessage()));
            emit confirmButtonRead(false, QString());
            return;
        }
        emit confirmButtonRead(true, reply.arguments().at(0).value<QDBusVariant>().variant().toString());
    });
}

void DBusInputBackend::onPropertiesChanged(const QString &interface, const QVariantMap &changed,
                                           const QStringList &invalidated)
{
    if (interface == Interface
        && (changed.contains(QStringLiteral("ConfirmButton")) || invalidated.contains(QStringLiteral("ConfirmButton"))))
        emit confirmButtonChanged();
}

void DBusInputBackend::onActiveInputChanged(const QString &deviceId, const QString &family)
{
    emit activeInputChanged(deviceId, family);
}

void DBusInputBackend::onProfilesChanged(const QString &profile)
{
    emit profilesChanged(profile);
}

// Every profile call is built from the table (InputProfileCalls.h): the in-arguments in the XML's
// order, the reply read back by the XML's out-argument names.
void DBusInputBackend::callProfile(quint64 token, const QString &method, const QVariantMap &args)
{
    const InputProfileMethod *m = InputProfileCalls::find(method);
    const auto failed = [m]() {
        QVariantMap reply;
        if (m) {
            for (const QString &name : m->out)
                reply.insert(name, QVariant());
        }
        reply.insert(QStringLiteral("status"), QStringLiteral("failed"));
        return reply;
    };
    if (!m) {
        QMetaObject::invokeMethod(this, [this, token, method, args, failed] { emit profileReply(token, method, args, failed()); },
                                  Qt::QueuedConnection);
        return;
    }
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    for (const QString &name : m->in)
        msg << args.value(name).toString();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, token, method, args, m, failed](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage reply = w->reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() != m->out.size()) {
            qWarning("ruya-shell: Input1 %s failed: %s", qPrintable(method), qPrintable(reply.errorMessage()));
            emit profileReply(token, method, args, failed());
            return;
        }
        QVariantMap out;
        for (int i = 0; i < m->out.size(); ++i) {
            const QVariant value = reply.arguments().at(i);
            if (value.canConvert<QDBusArgument>()) {
                // aa{sv}: the profile summaries of ListProfiles.
                QVariantList rows;
                const QDBusArgument arg = value.value<QDBusArgument>();
                arg.beginArray();
                while (!arg.atEnd())
                    rows.append(summaryOf(parseDict(arg)));
                arg.endArray();
                out.insert(m->out.at(i), rows);
            } else {
                out.insert(m->out.at(i), value);
            }
        }
        emit profileReply(token, method, args, out);
    });
}
