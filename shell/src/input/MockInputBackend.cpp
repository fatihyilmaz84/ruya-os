#include "MockInputBackend.h"

#include "InputProfileCalls.h"

#include <QCoreApplication>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QRegularExpression>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>
#include <QWindow>

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
                int battery, bool charging, const QVariantList &capabilities, const QString &model = QString())
{
    return {
        {QStringLiteral("id"), id},
        {QStringLiteral("instance"), id + QStringLiteral("#1")},
        {QStringLiteral("name"), name},
        {QStringLiteral("family"), family},
        {QStringLiteral("connection"), connection},
        {QStringLiteral("model"), model},
        {QStringLiteral("layout"), QString()},
        {QStringLiteral("battery"), battery},
        {QStringLiteral("charging"), charging},
        {QStringLiteral("slot"), 0u},
        {QStringLiteral("profile"), QString()},
        {QStringLiteral("owner"), QString()},
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
    , m_profiles(
          [this](const QString &deviceId) {
              for (const QVariant &d : std::as_const(m_devices)) {
                  const QVariantMap record = d.toMap();
                  if (record.value(QStringLiteral("id")).toString() != deviceId)
                      continue;
                  // Connected: never a null string, also without a family.
                  const QString family = record.value(QStringLiteral("family")).toString();
                  return family.isNull() ? QStringLiteral("") : family;
              }
              return QString();
          },
          validAppId)
{
    setDefaultDevices();
    m_clock.start();
    m_holdTimer.setSingleShot(true);
    connect(&m_holdTimer, &QTimer::timeout, this, &MockInputBackend::expireHolds);
}

// The service's expire_holds (RUY-627): seats 2-4 are freed, seat 1 keeps its profile without a pad.
void MockInputBackend::expireHolds()
{
    const qint64 now = m_clock.elapsed();
    const QVariantList before = playerList();
    qint64 next = 0;
    for (int i = 0; i < m_seats.size(); ++i) {
        Seat &s = m_seats[i];
        if (s.heldUntil == 0)
            continue;
        if (s.heldUntil > now) {
            next = next == 0 ? s.heldUntil : std::min(next, s.heldUntil);
            continue;
        }
        if (i == 0) {
            s.device.clear();
            s.heldUntil = 0;
        } else {
            s = {};
        }
    }
    seatsChanged(before);
    if (next > 0)
        m_holdTimer.start(int(std::max<qint64>(0, next - now)));
}

void MockInputBackend::resetDevices()
{
    m_listFail = false;
    m_tests.clear();
    m_stickNavigates = false;
    m_stickDown.clear();
    m_navigator.clear();
    m_foreignPress.clear();
    m_owners.clear();
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
            describe(dualsense, pads + motion + QStringList{QStringLiteral("touchpad"), QStringLiteral("battery")}),
            QStringLiteral("dualsense")),
        pad(QStringLiteral("usb-045e-0b12-8e01c2d4a9f3"), QStringLiteral("Xbox Wireless Controller"),
            QStringLiteral("xbox"), QStringLiteral("usb"), -1, false, describe(xboxOne, pads),
            QStringLiteral("xbox_series")),
        pad(QStringLiteral("bluetooth-057e-2009-b7c0e1f2a3d4"), QStringLiteral("Pro Controller"),
            QStringLiteral("nintendo"), QStringLiteral("bluetooth"), 12, false,
            describe(switchPro, switchUsable, motion), QStringLiteral("switch_pro")),
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

void MockInputBackend::startTest(const QString &deviceId, bool holdLeftStick)
{
    const bool known = std::any_of(m_devices.cbegin(), m_devices.cend(), [&deviceId](const QVariant &d) {
        return d.toMap().value(QStringLiteral("id")).toString() == deviceId;
    });
    QString status = QStringLiteral("ok");
    if (m_fail)
        status = QStringLiteral("failed");
    else if (!known)
        status = QStringLiteral("unknown-device");
    else if (m_route != QLatin1String("shell") && m_route != QLatin1String("overlay"))     // RUY-611: a game held behind Home
        status = QStringLiteral("not-allowed");
    else if (m_tests.contains(deviceId))
        status = QStringLiteral("busy");
    if (status == QLatin1String("ok")) {
        m_tests.insert(deviceId);
        m_holds.insert(deviceId, holdLeftStick);
        m_stickDown.remove(deviceId + QLatin1String("/left_x"));
        m_stickDown.remove(deviceId + QLatin1String("/left_y"));
    }
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
    // RUY-627: the pad is back within its seat's hold, and sits there again.
    const int at = seatOfDevice(id);
    if (at >= 0 && m_seats.at(at).heldUntil != 0) {
        const QVariantList before = playerList();
        m_seats[at].heldUntil = 0;
        seatsChanged(before);
    }
    QTimer::singleShot(0, this, [this] { emit devicesChanged(); });
}

void MockInputBackend::removeDevice(const QString &id)
{
    m_devices.removeIf([&id](const QVariant &d) { return d.toMap().value(QStringLiteral("id")).toString() == id; });
    // A seated pad holds its seat (RUY-627, seat 1 too); expireHolds ends the hold.
    const int at = seatOfDevice(id);
    if (at >= 0 && m_seats.at(at).heldUntil == 0) {
        const QVariantList before = playerList();
        m_seats[at].heldUntil = m_clock.elapsed() + m_seatHoldMs;
        seatsChanged(before);
        if (!m_holdTimer.isActive() || m_holdTimer.remainingTime() > m_seatHoldMs)
            m_holdTimer.start(m_seatHoldMs);
    }
    if (m_padSinceChange == id)
        m_padSinceChange.clear();
    if (m_navigator == id)
        m_navigator.clear();
    endTest(id, QStringLiteral("gone"));
    QTimer::singleShot(0, this, [this] { emit devicesChanged(); });
}

void MockInputBackend::sendTestInput(const QString &id, const QString &input, int value, const QString &source)
{
    if (!m_tests.contains(id))
        return;
    emit testInput(id, input, value, source);
    if (!m_stickNavigates || m_holds.value(id) || (input != QLatin1String("left_x") && input != QLatin1String("left_y")))
        return;
    // The service's path: past half travel one arrow key, again only after the stick came back.
    const bool horizontal = input == QLatin1String("left_x");
    const QString slot = id + QLatin1Char('/') + input;
    const int dir = value >= 16384 ? 1 : (value <= -16384 ? -1 : 0);
    if (dir == m_stickDown.value(slot, 0))
        return;
    if (dir == 0)
        m_stickDown.remove(slot);
    else
        m_stickDown.insert(slot, dir);
    if (dir == 0)
        return;
    const int key = horizontal ? (dir < 0 ? Qt::Key_Left : Qt::Key_Right) : (dir < 0 ? Qt::Key_Up : Qt::Key_Down);
    QWindow *window = QGuiApplication::focusWindow();
    if (!window)
        return;
    QKeyEvent press(QEvent::KeyPress, key, Qt::NoModifier);
    QKeyEvent release(QEvent::KeyRelease, key, Qt::NoModifier);
    QCoreApplication::sendEvent(window, &press);
    QCoreApplication::sendEvent(window, &release);
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
        const bool profileChanged = profile != m_profile;
        m_route = route;
        m_instance = instance;
        m_profile = profile;
        if (profileChanged) {
            QTimer::singleShot(0, this, [this] { emit confirmButtonChanged(); });
            // RUY-121: the new profile is seat 1, on the pad that pressed since the last change.
            const QVariantList before = playerList();
            m_seats.clear();
            if (!profile.isEmpty()) {
                m_seats = QList<Seat>(4);
                m_seats[0] = {profile, m_padSinceChange};
                if (!m_padSinceChange.isEmpty())
                    m_owners.insert(m_padSinceChange, profile);   // the pad's owner is learned (RUY-124)
            }
            m_padSinceChange.clear();
            m_navigator.clear();
            seatsChanged(before);
        }
        if (route == QLatin1String("app") || route == QLatin1String("locked")) {      // like inputd (RUY-611)
            const QList<QString> running = m_tests.values();
            for (const QString &id : running)
                endTest(id, QStringLiteral("route"));
        }
    }
    QTimer::singleShot(0, this, [this, request, status] { deliverRoute(request, status); });
}

void MockInputBackend::readConfirmButton()
{
    const bool ok = !m_fail;
    const QString mode = confirmButtonOf(m_profile, m_activeDevice);
    QTimer::singleShot(0, this, [this, ok, mode] { emit confirmButtonRead(ok, ok ? mode : QString()); });
}

namespace {
// The service's rules (routing.rs): a profile account (the mock takes any id of the profile form)
// and a stable device id (profile.rs valid_device).
bool consoleIdOk(const QString &profile)
{
    static const QRegularExpression re(QStringLiteral("^[A-Za-z0-9_-]{1,32}$"));
    return re.match(profile).hasMatch();
}
bool deviceIdOk(const QString &device)
{
    static const QRegularExpression re(QStringLiteral("^[a-z0-9:-]{1,64}$"));
    return re.match(device).hasMatch();
}
} // namespace

void MockInputBackend::readConfirmButtons(const QString &profile)
{
    const quint64 request = beginConfirmsRequest();
    const QString status = m_fail                  ? QStringLiteral("failed")
                           : !consoleIdOk(profile) ? QStringLiteral("unknown-profile")
                                                   : QStringLiteral("ok");
    // What the service holds now, also when the answer is late.
    const QVariantMap buttons = status == QLatin1String("ok") ? m_confirm.value(profile) : QVariantMap();
    QTimer::singleShot(m_confirmsDelayed ? 300 : 0, this,
                       [this, request, profile, status, buttons] { deliverConfirms(request, profile, status, buttons); });
}

void MockInputBackend::sendActiveInput(const QString &deviceId, const QString &family)
{
    const bool other = deviceId != m_activeDevice;
    const QString before = confirmButtonOf(m_profile, m_activeDevice);
    m_activeDevice = deviceId;
    m_padSinceChange = deviceId;
    emit activeInputChanged(deviceId, family);
    if (other && confirmButtonOf(m_profile, deviceId) != before)
        QTimer::singleShot(0, this, [this] { emit confirmButtonChanged(); });
}

void MockInputBackend::restart()
{
    m_tests.clear();
    m_route = QStringLiteral("shell");
    m_instance.clear();
    m_profile.clear();
    m_activeDevice.clear();   // a restarted service has seen no press yet
    m_pads = false;
    // Nor does it know the seats; a process that is gone sends no PlayersChanged.
    m_seats.clear();
    m_padSinceChange.clear();
    m_navigator.clear();
    m_foreignPress.clear();
    applySeatsToDevices();
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

void MockInputBackend::holdSaves(bool hold)
{
    m_holdSaves = hold;
    if (hold)
        return;
    const QList<HeldCall> held = m_held;
    m_held.clear();
    m_replaying = true;
    for (const HeldCall &h : held)
        callProfile(h.token, QStringLiteral("SaveProfile"), h.args);
    m_replaying = false;
}

void MockInputBackend::callProfile(quint64 token, const QString &method, const QVariantMap &args)
{
    if (!m_replaying)
        m_profileCalls.append(QVariantMap{{QStringLiteral("method"), method}, {QStringLiteral("args"), args}});
    if (m_holdSaves && method == QLatin1String("SaveProfile")) {
        m_held.append({token, args});
        return;
    }
    QVariantMap reply;
    QString changed;
    if (m_fail || m_forcedStatus.contains(method)) {
        if (const InputProfileMethod *m = InputProfileCalls::find(method)) {
            for (const QString &name : m->out)
                reply.insert(name, QVariant());
        }
        reply.insert(QStringLiteral("status"), m_fail ? QStringLiteral("failed") : m_forcedStatus.value(method));
        if (m_forcedOnce.remove(method))
            m_forcedStatus.remove(method);
    } else if (method == QLatin1String("SetConfirmButton")) {
        // The service's rules (routing.rs): the profile account, the mode, then the device id; the
        // answer is ok, unknown-profile or invalid. "family" removes the pad's choice.
        const QString profile = args.value(QStringLiteral("profile")).toString();
        const QString device = args.value(QStringLiteral("device")).toString();
        const QString mode = args.value(QStringLiteral("mode")).toString();
        QString status = QStringLiteral("ok");
        if (!consoleIdOk(profile))
            status = QStringLiteral("unknown-profile");
        else if (mode != QLatin1String("family") && mode != QLatin1String("south") && mode != QLatin1String("east"))
            status = QStringLiteral("invalid");
        else if (!deviceIdOk(device))
            status = QStringLiteral("invalid");
        reply.insert(QStringLiteral("status"), status);
        if (status == QLatin1String("ok")) {
            const QString before = confirmButtonOf(profile, device);
            QVariantMap &pads = m_confirm[profile];
            if (mode == QLatin1String("family"))
                pads.remove(device);
            else
                pads.insert(device, mode);
            if (profile == m_profile && device == m_activeDevice && mode != before)
                QTimer::singleShot(0, this, [this] { emit confirmButtonChanged(); });
            m_profiles.noteStored(profile); // the settings file is in the console profile's directory
        }
    } else {
        reply = m_profiles.call(method, args, &changed);
        // The settings file goes with the directory (RUY-468).
        if (method == QLatin1String("ForgetConsoleProfile") && reply.value(QStringLiteral("status")) == QLatin1String("ok"))
            m_confirm.remove(args.value(QStringLiteral("profile")).toString());
    }
    QTimer::singleShot(0, this, [this, token, method, args, reply, changed] {
        emit profileReply(token, method, args, reply);
        if (!changed.isEmpty())
            emit profilesChanged(changed);
    });
}

QVariantList MockInputBackend::playerList() const
{
    QVariantList out;
    const qint64 now = m_clock.elapsed();
    for (int i = 0; i < m_seats.size(); ++i) {
        const Seat &s = m_seats.at(i);
        if (s.profile.isEmpty())
            continue;
        // held_secs: the whole seconds left, rounded up (seats.rs Player::held_secs).
        const qint64 left = s.heldUntil == 0 ? 0 : std::max<qint64>(0, s.heldUntil - now);
        out.append(QVariantMap{
            {QStringLiteral("slot"), uint(i + 1)},
            {QStringLiteral("profile"), s.profile},
            {QStringLiteral("device_id"), s.device},
            {QStringLiteral("held"), s.heldUntil != 0},
            {QStringLiteral("held_secs"), uint((left + 999) / 1000)},
        });
    }
    return out;
}

int MockInputBackend::seatOfDevice(const QString &deviceId) const
{
    if (deviceId.isEmpty())
        return -1;
    for (int i = 0; i < m_seats.size(); ++i) {
        if (!m_seats.at(i).profile.isEmpty() && m_seats.at(i).device == deviceId)
            return i;
    }
    return -1;
}

// The device records' slot and profile from the seats; true when one changed.
bool MockInputBackend::applySeatsToDevices()
{
    bool changed = false;
    for (QVariant &d : m_devices) {
        QVariantMap record = d.toMap();
        const int at = seatOfDevice(record.value(QStringLiteral("id")).toString());
        const uint slot = at >= 0 ? uint(at + 1) : 0u;
        const QString profile = at >= 0 ? m_seats.at(at).profile : QString();
        const QString owner = m_owners.value(record.value(QStringLiteral("id")).toString());
        if (record.value(QStringLiteral("slot")).toUInt() == slot
            && record.value(QStringLiteral("profile")).toString() == profile
            && record.value(QStringLiteral("owner")).toString() == owner)
            continue;
        record.insert(QStringLiteral("slot"), slot);
        record.insert(QStringLiteral("profile"), profile);
        record.insert(QStringLiteral("owner"), owner);
        d = record;
        changed = true;
    }
    return changed;
}

void MockInputBackend::seatsChanged(const QVariantList &before)
{
    if (applySeatsToDevices())
        QTimer::singleShot(0, this, [this] { emit devicesChanged(); });
    const QVariantList now = playerList();
    // A signal from a service whose name has no owner is not heard.
    if (now != before && serviceOwned())
        QTimer::singleShot(m_playersDelayMs, this, [this, now] { deliverPlayersSignal(now); });
}

// The service's rules (routing.rs join_player, seats.rs): the checks in the XML's order, then
// rules (a) to (e); "full" changes nothing.
void MockInputBackend::joinPlayer(const QString &deviceId, const QString &profile)
{
    const bool known = std::any_of(m_devices.cbegin(), m_devices.cend(), [&deviceId](const QVariant &d) {
        return d.toMap().value(QStringLiteral("id")).toString() == deviceId;
    });
    QString status = QStringLiteral("ok");
    uint slot = 0;
    if (m_fail)
        status = QStringLiteral("failed");
    else if (!m_failJoin.isEmpty())
        status = m_failJoin;
    else if (!deviceIdOk(deviceId))
        status = QStringLiteral("invalid");
    else if (m_seats.isEmpty())
        status = QStringLiteral("not-allowed");
    else if (!consoleIdOk(profile))
        status = QStringLiteral("unknown-profile");
    else if (!known)
        status = QStringLiteral("unknown-device");
    if (status == QLatin1String("ok")) {
        const int at = seatOfDevice(deviceId);
        if (at >= 0 && m_seats.at(at).profile == profile) {
            slot = uint(at + 1);                         // (e) the same again: nothing changes
            m_owners.insert(deviceId, profile);
        } else {
            QList<Seat> next = m_seats;
            if (at == 0)
                next[0].device.clear();                  // (c) player 1 stays, without a pad
            else if (at > 0)
                next[at] = {};                           // (c) that profile leaves first
            int mine = -1;
            for (int i = 0; i < next.size(); ++i) {
                if (next.at(i).profile == profile)
                    mine = i;
            }
            if (mine >= 0) {
                next[mine].device = deviceId;            // (a), (b): the seat moves to the pad
                next[mine].heldUntil = 0;                // and a hold of it ends (RUY-627)
            } else {
                for (int i = 1; i < next.size() && mine < 0; ++i) {
                    if (next.at(i).profile.isEmpty())
                        mine = i;                        // (d) the lowest free seat of 2-4
                }
                if (mine >= 0)
                    next[mine] = {profile, deviceId, 0};
            }
            if (mine < 0) {
                status = QStringLiteral("full");
            } else {
                const QVariantList before = playerList();
                m_seats = next;
                m_owners.insert(deviceId, profile);   // the last profile seated on the pad (RUY-124)
                slot = uint(mine + 1);
                seatsChanged(before);
            }
        }
    }
    QTimer::singleShot(0, this, [this, deviceId, profile, status, slot] {
        emit joinFinished(deviceId, profile, status, slot);
    });
}

void MockInputBackend::leavePlayer(uint slot)
{
    QString status = QStringLiteral("ok");
    if (m_fail)
        status = QStringLiteral("failed");
    else if (slot == 0 || slot > 4)
        status = QStringLiteral("invalid");
    else if (m_seats.isEmpty() || slot == 1)
        status = QStringLiteral("not-allowed");
    if (status == QLatin1String("ok") && !m_seats.at(int(slot) - 1).profile.isEmpty()) {
        const QVariantList before = playerList();
        m_seats[int(slot) - 1] = {};
        seatsChanged(before);
    }
    QTimer::singleShot(0, this, [this, slot, status] { emit leaveFinished(slot, status); });
}

void MockInputBackend::refreshPlayers()
{
    const quint64 request = beginPlayersRequest();
    const bool ok = !m_fail;
    const QVariantList list = ok ? playerList() : QVariantList();
    QTimer::singleShot(0, this, [this, request, ok, list] { deliverPlayers(request, ok, list); });
}

// routing.rs `navigates` (06 §11.3, RUY-38).
bool MockInputBackend::navigates(const QString &deviceId) const
{
    if (m_seats.isEmpty())
        return true;
    if (!m_navigator.isEmpty())
        return deviceId == m_navigator;
    const Seat &first = m_seats.at(0);
    return !first.device.isEmpty() && first.device == deviceId && first.heldUntil == 0;
}

void MockInputBackend::setNavigator(const QString &deviceId)
{
    const auto record = std::find_if(m_devices.cbegin(), m_devices.cend(), [&deviceId](const QVariant &d) {
        return d.toMap().value(QStringLiteral("id")).toString() == deviceId;
    });
    QString status = QStringLiteral("ok");
    if (m_fail)
        status = QStringLiteral("failed");
    else if (deviceId.isEmpty())
        m_navigator.clear();
    else if (m_seats.isEmpty())
        status = QStringLiteral("not-allowed");
    else if (record == m_devices.cend())
        status = QStringLiteral("unknown-device");
    else {
        // The service announces the navigator as the active input at the call (its glyphs, its
        // Confirm choice), before it answers.
        m_navigator = deviceId;
        const QString family = record->toMap().value(QStringLiteral("family")).toString();
        const QString before = confirmButtonOf(m_profile, m_activeDevice);
        m_activeDevice = deviceId;
        const bool modeChanged = confirmButtonOf(m_profile, deviceId) != before;
        QTimer::singleShot(0, this, [this, deviceId, family, modeChanged] {
            emit activeInputChanged(deviceId, family);
            if (modeChanged)
                emit confirmButtonChanged();
        });
    }
    QTimer::singleShot(0, this, [this, deviceId, status] { emit navigatorFinished(deviceId, status); });
}

int MockInputBackend::padButton(const QString &deviceId, const QString &button)
{
    const auto record = std::find_if(m_devices.cbegin(), m_devices.cend(), [&deviceId](const QVariant &d) {
        return d.toMap().value(QStringLiteral("id")).toString() == deviceId;
    });
    if (record == m_devices.cend() || m_fail || !serviceOwned())
        return 0;
    const bool guide = button == QLatin1String("guide");
    if (!navigates(deviceId)) {
        // Seat 1's pad (a navigator is set) asks for nothing; seats 2-4 ask with their Guide only; an
        // unseated pad's Guide is "guide", its other buttons "press" at most once a second.
        const int seat = seatOfDevice(deviceId);
        QString kind;
        if (seat > 0 && guide) {
            kind = QStringLiteral("player-guide");
        } else if (seat < 0 && guide) {
            kind = QStringLiteral("guide");
        } else if (seat < 0) {
            const qint64 now = m_clock.elapsed();
            const auto last = m_foreignPress.constFind(deviceId);
            if (last == m_foreignPress.cend() || now - last.value() >= 1000) {
                m_foreignPress.insert(deviceId, now);
                kind = QStringLiteral("press");
            }
        }
        if (!kind.isEmpty())
            QTimer::singleShot(0, this, [this, deviceId, kind] { emit foreignInput(deviceId, kind); });
        return 0;
    }
    const QString family = record->toMap().value(QStringLiteral("family")).toString();
    if (deviceId != m_activeDevice)
        sendActiveInput(deviceId, family);
    else
        m_padSinceChange = deviceId;
    // Under "app" a pad that navigates gives the shell its Guide only.
    if (m_route == QLatin1String("app") && !guide)
        return 0;
    // mapping.rs nav_key: the confirming button by the pad's Confirm choice and family (06 §11.2).
    const QString mode = confirmButtonOf(m_profile, deviceId);
    const bool eastConfirms = mode == QLatin1String("east")
                              || (mode == QLatin1String("family") && family == QLatin1String("nintendo"));
    if (button == QLatin1String("south"))
        return eastConfirms ? Qt::Key_Escape : Qt::Key_Return;
    if (button == QLatin1String("east"))
        return eastConfirms ? Qt::Key_Return : Qt::Key_Escape;
    static const QHash<QString, int> keys = {
        {QStringLiteral("start"), Qt::Key_Menu},        {QStringLiteral("guide"), Qt::Key_HomePage},
        {QStringLiteral("dpad_up"), Qt::Key_Up},        {QStringLiteral("dpad_down"), Qt::Key_Down},
        {QStringLiteral("dpad_left"), Qt::Key_Left},    {QStringLiteral("dpad_right"), Qt::Key_Right},
        {QStringLiteral("l1"), Qt::Key_PageUp},         {QStringLiteral("r1"), Qt::Key_PageDown},
    };
    return keys.value(button, 0);
}
