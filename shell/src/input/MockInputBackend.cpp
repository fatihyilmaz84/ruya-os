#include "MockInputBackend.h"

#include <QStringList>
#include <QTimer>
#include <QVariantMap>

#include <algorithm>

namespace {
// The rule of Session1 and ruya-inputd (accounts.rs valid_app_id): three dot-separated parts or
// more, each of letters, digits, '_' and '-', not starting with a digit.
bool validAppId(const QString &id)
{
    if (id.isEmpty() || id.size() > 255)
        return false;
    const QStringList parts = id.split(QLatin1Char('.'));
    if (parts.size() < 3)
        return false;
    for (const QString &p : parts) {
        if (p.isEmpty() || p.at(0).isDigit())
            return false;
        for (const QChar c : p) {
            const bool ascii = c.unicode() < 128;
            if (!ascii || !(c.isLetterOrNumber() || c == QLatin1Char('_') || c == QLatin1Char('-')))
                return false;
        }
    }
    return true;
}

// The descriptor of ruya-inputd's rules (services/ruya-inputd/src/caps.rs): every name in order;
// `model` what the device table says the model has, `usable` the parts that work here, `present`
// the parts whose node exists but does not open.
QVariantList describe(const QStringList &model, const QStringList &usable, const QStringList &present = {})
{
    static const QStringList names = {
        QStringLiteral("buttons"), QStringLiteral("sticks"), QStringLiteral("analog_triggers"),
        QStringLiteral("dpad"), QStringLiteral("gyro"), QStringLiteral("accelerometer"),
        QStringLiteral("touchpad"), QStringLiteral("rumble"), QStringLiteral("trigger_rumble"),
        QStringLiteral("adaptive_triggers"), QStringLiteral("lightbar"), QStringLiteral("player_leds"),
        QStringLiteral("speaker"), QStringLiteral("microphone"), QStringLiteral("battery"),
    };
    static const QStringList output = {
        QStringLiteral("buttons"), QStringLiteral("sticks"), QStringLiteral("analog_triggers"),
        QStringLiteral("dpad"), QStringLiteral("rumble"),
    };
    QVariantList out;
    for (const QString &n : names) {
        const bool driver = usable.contains(n) || present.contains(n);
        const bool available = usable.contains(n);
        out.append(QVariantMap{
            {QStringLiteral("name"), n},
            {QStringLiteral("hardware"), driver || model.contains(n)},
            {QStringLiteral("driver"), driver},
            {QStringLiteral("available"), available},
            {QStringLiteral("output"), available && output.contains(n)},
        });
    }
    return out;
}

QVariantMap pad(const QString &id, const QString &name, const QString &family, const QString &connection,
                int battery, bool charging, const QVariantList &capabilities)
{
    return {
        {QStringLiteral("id"), id},
        {QStringLiteral("instance"), id + QStringLiteral("#1")},
        {QStringLiteral("name"), name},
        {QStringLiteral("family"), family},
        {QStringLiteral("connection"), connection},
        {QStringLiteral("battery"), battery},
        {QStringLiteral("charging"), charging},
        {QStringLiteral("slot"), 0u},
        {QStringLiteral("profile"), QString()},
        {QStringLiteral("routed"), false},
        {QStringLiteral("capabilities"), capabilities},
    };
}

QVariantMap withoutCapabilities(QVariantMap d)
{
    d.remove(QStringLiteral("capabilities"));
    return d;
}
} // namespace

MockInputBackend::MockInputBackend(QObject *parent)
    : InputBackend(parent)
{
    setDefaultDevices();
}

void MockInputBackend::resetDevices()
{
    m_listFail = false;
    m_tests.clear();
    setDefaultDevices();
    QTimer::singleShot(0, this, [this] { emit devicesChanged(); });
}

void MockInputBackend::setDefaultDevices()
{
    const QStringList pads = {QStringLiteral("buttons"), QStringLiteral("sticks"), QStringLiteral("analog_triggers"),
                              QStringLiteral("dpad"), QStringLiteral("rumble")};
    const QStringList motion = {QStringLiteral("gyro"), QStringLiteral("accelerometer")};
    const QStringList dualsense = pads + motion + QStringList{
        QStringLiteral("touchpad"), QStringLiteral("adaptive_triggers"), QStringLiteral("lightbar"),
        QStringLiteral("player_leds"), QStringLiteral("speaker"), QStringLiteral("microphone"),
        QStringLiteral("battery")};
    const QStringList xboxOne = pads + QStringList{QStringLiteral("trigger_rumble"), QStringLiteral("battery")};
    const QStringList switchPro = {QStringLiteral("buttons"), QStringLiteral("sticks"), QStringLiteral("dpad"),
                                   QStringLiteral("gyro"), QStringLiteral("accelerometer"), QStringLiteral("rumble"),
                                   QStringLiteral("player_leds"), QStringLiteral("battery")};
    const QStringList switchUsable = {QStringLiteral("buttons"), QStringLiteral("sticks"), QStringLiteral("dpad"),
                                      QStringLiteral("rumble"), QStringLiteral("battery")};
    m_devices = {
        pad(QStringLiteral("bluetooth-054c-0ce6-3f2a9c41d0b7"), QStringLiteral("DualSense Wireless Controller"),
            QStringLiteral("playstation"), QStringLiteral("bluetooth"), 62, true,
            describe(dualsense, pads + motion + QStringList{QStringLiteral("touchpad"), QStringLiteral("battery")})),
        pad(QStringLiteral("usb-045e-0b12-8e01c2d4a9f3"), QStringLiteral("Xbox Wireless Controller"),
            QStringLiteral("xbox"), QStringLiteral("usb"), -1, false, describe(xboxOne, pads)),
        pad(QStringLiteral("bluetooth-057e-2009-b7c0e1f2a3d4"), QStringLiteral("Pro Controller"),
            QStringLiteral("nintendo"), QStringLiteral("bluetooth"), 12, false,
            describe(switchPro, switchUsable, motion)),
    };
}

void MockInputBackend::refreshDevices()
{
    const quint64 request = beginDevicesRequest();
    const bool ok = !m_listFail && !m_fail;
    QVariantList list;
    if (ok) {
        for (const QVariant &d : std::as_const(m_devices))
            list.append(withoutCapabilities(d.toMap()));
    }
    QTimer::singleShot(0, this, [this, request, ok, list] { deliverDevices(request, ok, list); });
}

void MockInputBackend::getCapabilities(const QString &deviceId)
{
    QString status = QStringLiteral("unknown-device");
    QVariantList caps;
    if (m_listFail || m_fail) {
        status = QStringLiteral("failed");
    } else {
        for (const QVariant &d : std::as_const(m_devices)) {
            const QVariantMap m = d.toMap();
            if (m.value(QStringLiteral("id")).toString() == deviceId) {
                status = QStringLiteral("ok");
                caps = m.value(QStringLiteral("capabilities")).toList();
            }
        }
    }
    QTimer::singleShot(0, this, [this, deviceId, status, caps] { emit capabilitiesFinished(deviceId, status, caps); });
}

void MockInputBackend::startTest(const QString &deviceId)
{
    const bool known = std::any_of(m_devices.cbegin(), m_devices.cend(), [&deviceId](const QVariant &d) {
        return d.toMap().value(QStringLiteral("id")).toString() == deviceId;
    });
    QString status = QStringLiteral("ok");
    if (m_fail)
        status = QStringLiteral("failed");
    else if (!known)
        status = QStringLiteral("unknown-device");
    else if (m_route != QLatin1String("shell"))
        status = QStringLiteral("not-allowed");
    else if (m_tests.contains(deviceId))
        status = QStringLiteral("busy");
    if (status == QLatin1String("ok"))
        m_tests.insert(deviceId);
    QTimer::singleShot(0, this, [this, deviceId, status] { emit testStartFinished(deviceId, status); });
}

void MockInputBackend::stopTest(const QString &deviceId)
{
    if (m_tests.remove(deviceId))
        QTimer::singleShot(0, this, [this, deviceId] { emit testEnded(deviceId, QStringLiteral("stopped")); });
}

void MockInputBackend::addDevice(const QVariantMap &device)
{
    const QString id = device.value(QStringLiteral("id")).toString();
    QVariantMap d = pad(id, QString(), QString(), QString(), -1, false, {});
    for (auto it = device.cbegin(); it != device.cend(); ++it)
        d.insert(it.key(), it.value());
    bool replaced = false;
    for (QVariant &e : m_devices) {
        if (e.toMap().value(QStringLiteral("id")).toString() == id) {
            e = d;
            replaced = true;
        }
    }
    if (!replaced)
        m_devices.append(d);
    QTimer::singleShot(0, this, [this] { emit devicesChanged(); });
}

void MockInputBackend::removeDevice(const QString &id)
{
    m_devices.removeIf([&id](const QVariant &d) { return d.toMap().value(QStringLiteral("id")).toString() == id; });
    endTest(id, QStringLiteral("gone"));
    QTimer::singleShot(0, this, [this] { emit devicesChanged(); });
}

void MockInputBackend::sendTestInput(const QString &id, const QString &input, int value, const QString &source)
{
    if (m_tests.contains(id))
        emit testInput(id, input, value, source);
}

void MockInputBackend::endTest(const QString &id, const QString &reason)
{
    if (m_tests.remove(id))
        QTimer::singleShot(0, this, [this, id, reason] { emit testEnded(id, reason); });
}

void MockInputBackend::setRoute(const QString &route, const QString &instance, const QString &appId,
                                const QString &profile)
{
    const quint64 request = beginRoute();
    m_calls.append(QVariantMap{
        {QStringLiteral("route"), route},
        {QStringLiteral("instance"), instance},
        {QStringLiteral("appId"), appId},
        {QStringLiteral("profile"), profile},
    });
    QString status = QStringLiteral("ok");
    const bool appOk = appId.isEmpty() || validAppId(appId);
    bool shapeOk = false;
    if (route == QLatin1String("app"))
        shapeOk = !instance.isEmpty() && !appId.isEmpty() && !profile.isEmpty();
    else if (route == QLatin1String("overlay"))
        shapeOk = !profile.isEmpty() && instance.isEmpty() == appId.isEmpty();
    else if (route == QLatin1String("shell"))
        shapeOk = instance.isEmpty() && appId.isEmpty();
    else if (route == QLatin1String("locked"))
        shapeOk = instance.isEmpty() && appId.isEmpty() && profile.isEmpty();
    if (m_fail)
        status = QStringLiteral("failed");
    else if (!shapeOk || !appOk)
        status = QStringLiteral("invalid");

    if (status == QLatin1String("ok")) {
        const bool sameOwner = m_pads && !instance.isEmpty() && instance == m_instance && profile == m_profile;
        if (route == QLatin1String("app")) {
            if (!sameOwner) {
                m_pads = true;
                ++m_padGeneration;
            }
        } else if (!(route == QLatin1String("overlay") && sameOwner)) {
            m_pads = false;
        }
        m_route = route;
        m_instance = instance;
        m_profile = profile;
        if (route != QLatin1String("shell")) {
            const QList<QString> running = m_tests.values();
            for (const QString &id : running)
                endTest(id, QStringLiteral("route"));
        }
    }
    QTimer::singleShot(0, this, [this, request, status] { deliverRoute(request, status); });
}

void MockInputBackend::restart()
{
    m_tests.clear();
    m_route = QStringLiteral("shell");
    m_instance.clear();
    m_profile.clear();
    m_pads = false;
    setServiceOwned(true);
    QTimer::singleShot(0, this, [this] { emit serviceAppeared(); });
}

void MockInputBackend::setNameOwned(bool owned)
{
    const bool appeared = owned && !serviceOwned();
    setServiceOwned(owned);
    if (appeared)
        QTimer::singleShot(0, this, [this] { emit serviceAppeared(); });
}
