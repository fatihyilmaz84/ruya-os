#include "MockBluetoothBackend.h"

#include <algorithm>
#include <utility>

MockBluetoothBackend::MockBluetoothBackend(QObject *parent)
    : BluetoothBackend(parent)
{
    m_scanTimer.setSingleShot(true);
    m_scanTimer.setInterval(300);
    connect(&m_scanTimer, &QTimer::timeout, this, &MockBluetoothBackend::endScan);
    m_pairingTimer.setSingleShot(true);
    m_pairingTimer.setInterval(300);
    connect(&m_pairingTimer, &QTimer::timeout, this, [this] { finishPairing(m_pairingScript); });
    initState();
}

void MockBluetoothBackend::refresh()
{
    ++m_refreshCalls;
    publish(m_delay);
}

void MockBluetoothBackend::setPowered(bool on)
{
    if (on != m_powered) {
        m_powered = on;
        m_scanTimer.stop();
        m_discovering = false;
        if (!on) {
            m_pairingTimer.stop();
            if (m_pairing == QLatin1String("open"))
                m_pairing = QStringLiteral("idle");     // the window cannot outlive the adapter
        }
        for (Entry &e : m_entries) {
            if (!on) {
                e.reconnect = e.dev.connected;
                e.dev.connected = false;
                if (!e.dev.paired)
                    e.listed = false; // found-but-unpaired devices are forgotten
            } else {
                e.dev.connected = e.dev.paired && e.dev.trusted && e.reconnect;
                e.reconnect = false;
            }
        }
        if (!on)
            m_scans = 0;
        publish();
    }
    answer(QStringLiteral("power"), QString(), QStringLiteral("ok"));
}

void MockBluetoothBackend::startScan()
{
    if (!m_powered) {
        answer(QStringLiteral("scan"), QString(), QStringLiteral("unavailable"));
        return;
    }
    ++m_scans;
    for (Entry &e : m_entries) {
        if (e.appearAfter <= m_scans && !e.silent)
            e.listed = true;
    }
    m_discovering = true;
    m_scanTimer.start();
    publish();
    answer(QStringLiteral("scan"), QString(), QStringLiteral("ok"));
}

void MockBluetoothBackend::stopScan()
{
    m_scanTimer.stop();
    if (m_discovering)
        endScan();
    answer(QStringLiteral("scan"), QString(), QStringLiteral("ok"));
}

void MockBluetoothBackend::endScan()
{
    m_discovering = false;
    publish();
}

void MockBluetoothBackend::startControllerPairing(int seconds)
{
    Q_UNUSED(seconds)
    ++m_pairingStarts;
    QString status = QStringLiteral("ok");
    if (!m_powered)
        status = QStringLiteral("unavailable");
    else if (m_pairing == QLatin1String("open"))
        status = QStringLiteral("busy");
    else {
        m_pairing = QStringLiteral("open");
        publish();
        if (m_pairingScript != QLatin1String("wait"))
            m_pairingTimer.start();
    }
    answer(QStringLiteral("controller-pairing"), QStringLiteral("start"), status);
}

void MockBluetoothBackend::stopControllerPairing()
{
    m_pairingTimer.stop();
    if (m_pairing != QLatin1String("idle")) {
        m_pairing = QStringLiteral("idle");
        publish();
    }
    answer(QStringLiteral("controller-pairing"), QStringLiteral("stop"), QStringLiteral("ok"));
}

void MockBluetoothBackend::finishPairing(const QString &outcome)
{
    if (m_pairing != QLatin1String("open"))
        return;
    if (outcome == QLatin1String("rejected")) {
        emit controllerRejected();     // the window stays open
        return;
    }
    m_pairing = outcome == QLatin1String("success") ? QStringLiteral("paired") : QStringLiteral("timeout");
    if (outcome == QLatin1String("success")) {
        const int at = indexOf(QStringLiteral("bt-pad-new"));
        if (at >= 0) {
            Entry &e = m_entries[at];
            e.listed = true;
            e.dev.paired = e.dev.trusted = e.dev.connected = true;
            e.dev.bonded = true;
        }
        m_inputPresent = true;
    }
    publish();
}

void MockBluetoothBackend::setInputPresent(bool present)
{
    m_inputPresent = present;
    publish();
}

void MockBluetoothBackend::pair(const QString &id)
{
    ++m_pairCalls;
    if (m_holdPairing) {
        m_heldPairs.append(id);
        return;
    }
    doPair(id);
}

void MockBluetoothBackend::holdPairing(bool hold)
{
    m_holdPairing = hold;
    if (hold)
        return;
    const QStringList held = std::exchange(m_heldPairs, {});
    for (const QString &id : held)
        doPair(id);
}

void MockBluetoothBackend::doPair(const QString &id)
{
    const int at = indexOf(id);
    QString status = QStringLiteral("ok");
    if (id.isEmpty())
        status = QStringLiteral("invalid");
    else if (!m_powered)
        status = QStringLiteral("unavailable");
    else if (at < 0 || !m_entries.at(at).listed)
        status = QStringLiteral("unknown-device");
    else if (!m_entries.at(at).dev.paired)
        status = m_entries.at(at).pairResult;
    if (status == QLatin1String("ok")) {
        BtDevice &d = m_entries[at].dev;
        d.paired = d.trusted = d.connected = true;
        d.bonded = true;
        publish();
    }
    answer(QStringLiteral("pair"), id, status);
}

void MockBluetoothBackend::forget(const QString &id)
{
    const int at = indexOf(id);
    QString status = QStringLiteral("ok");
    if (id.isEmpty()) {
        status = QStringLiteral("invalid");
    } else if (at < 0 || !m_entries.at(at).listed) {
        status = QStringLiteral("unknown-device");
    } else {
        Entry &e = m_entries[at];
        e.dev.paired = e.dev.trusted = e.dev.connected = false;
        e.dev.bonded = false;
        e.listed = false; // it has to be found again
        e.appearAfter = 0;
        publish();
    }
    answer(QStringLiteral("forget"), id, status);
}

void MockBluetoothBackend::connectDevice(const QString &id)
{
    const int at = indexOf(id);
    QString status = QStringLiteral("ok");
    if (id.isEmpty())
        status = QStringLiteral("invalid");
    else if (!m_powered)
        status = QStringLiteral("unavailable");
    else if (at < 0 || !m_entries.at(at).listed)
        status = QStringLiteral("unknown-device");
    else if (!m_entries.at(at).dev.paired)
        status = QStringLiteral("failed");
    else {
        m_entries[at].dev.connected = true;
        publish();
    }
    answer(QStringLiteral("connect"), id, status);
}

void MockBluetoothBackend::disconnectDevice(const QString &id)
{
    const int at = indexOf(id);
    QString status = QStringLiteral("ok");
    if (id.isEmpty())
        status = QStringLiteral("invalid");
    else if (at < 0 || !m_entries.at(at).listed)
        status = QStringLiteral("unknown-device");
    else if (!m_entries.at(at).dev.paired)
        status = QStringLiteral("failed");
    else {
        m_entries[at].dev.connected = false;
        publish();
    }
    answer(QStringLiteral("disconnect"), id, status);
}

void MockBluetoothBackend::reportIdle(int idleSeconds, int timeoutSeconds, bool hold)
{
    ++m_idleReports;
    m_lastIdleSeconds = idleSeconds;
    m_lastIdleTimeout = timeoutSeconds;
    m_lastIdleHold = hold;
}

void MockBluetoothBackend::rename(const QString &id, const QString &name)
{
    const int at = indexOf(id);
    const QString trimmed = name.trimmed();
    QString status = QStringLiteral("ok");
    bool control = false;
    for (const QChar c : trimmed)
        control = control || c.category() == QChar::Other_Control;
    if (id.isEmpty() || trimmed.isEmpty() || trimmed.size() > 48 || control)
        status = QStringLiteral("invalid");
    else if (!m_powered)
        status = QStringLiteral("unavailable");
    else if (at < 0 || !m_entries.at(at).listed)
        status = QStringLiteral("unknown-device");
    else if (!m_entries.at(at).dev.paired)
        status = QStringLiteral("failed");
    else {
        m_entries[at].dev.name = trimmed;
        publish();
    }
    answer(QStringLiteral("rename"), id, status);
}

void MockBluetoothBackend::setName(const QString &id, const QString &name)
{
    const int at = indexOf(id);
    if (at >= 0) {
        m_entries[at].dev.name = name;
        publish();
    }
}

void MockBluetoothBackend::setFamily(const QString &id, const QString &family)
{
    const int at = indexOf(id);
    if (at >= 0) {
        m_entries[at].dev.family = family;
        publish();
    }
}

void MockBluetoothBackend::setBonded(const QString &id, bool bonded)
{
    const int at = indexOf(id);
    if (at >= 0) {
        m_entries[at].dev.bonded = bonded;
        publish();
    }
}

void MockBluetoothBackend::setSilent(const QString &id, bool silent)
{
    const int at = indexOf(id);
    if (at >= 0)
        m_entries[at].silent = silent;
}

void MockBluetoothBackend::reveal(const QString &id)
{
    const int at = indexOf(id);
    if (at >= 0 && !m_entries.at(at).listed) {
        m_entries[at].listed = true;
        publish();
    }
}

void MockBluetoothBackend::gamepadEvent(bool connected, const QString &id, const QString &name, const QString &family,
                                        const QString &transport)
{
    QTimer::singleShot(0, this, [this, connected, id, name, family, transport] {
        m_gamepads.removeIf([&id](const BtGamepad &p) { return p.id.compare(id, Qt::CaseInsensitive) == 0; });
        if (connected)
            m_gamepads.append({id, name, family, transport});
        deliverGamepads(beginGamepadsRequest(), gamepadList());
        if (connected)
            emit gamepadConnected(id, name, family, transport);
        else
            emit gamepadDisconnected(id, name, family, transport);
    });
}

void MockBluetoothBackend::setBattery(const QString &id, int percent)
{
    const int at = indexOf(id);
    if (at >= 0) {
        m_entries[at].dev.battery = percent;
        publish();
    }
}

// One paired, connected device of every kind and family (T-199): the pane's rows, the accessible
// names and the screenshots show them all. "gizmo" is a kind that no shell version knows.
void MockBluetoothBackend::populate()
{
    struct Spec { const char *id; const char *name; const char *kind; const char *family; };
    static const Spec specs[] = {
        {"bt-gallery-ps", "DualSense", "controller", "playstation"},
        {"bt-gallery-xbox", "Xbox Wireless Controller", "controller", "xbox"},
        {"bt-gallery-switch", "Pro Controller", "controller", "nintendo"},
        {"bt-gallery-8bitdo", "8BitDo Pro 2", "controller", "8bitdo"},
        {"bt-gallery-pad", "Generic Pad", "controller", ""},
        {"bt-gallery-headset", "WH-1000XM4", "headset", ""},
        {"bt-gallery-speaker", "Kitchen Speaker", "speaker", ""},
        {"bt-gallery-keyboard", "Living Room Keyboard", "keyboard", ""},
        {"bt-gallery-mouse", "Travel Mouse", "mouse", ""},
        {"bt-gallery-phone", "Fatma's Phone", "phone", ""},
        {"bt-gallery-other", "Fitness Band", "other", ""},
        {"bt-gallery-gizmo", "Mystery Gadget", "gizmo", ""},
    };
    for (const Spec &s : specs) {
        if (indexOf(QString::fromLatin1(s.id)) >= 0)
            continue;
        Entry e;
        e.dev.id = QString::fromLatin1(s.id);
        e.dev.name = QString::fromLatin1(s.name);
        e.dev.deviceName = e.dev.name;
        e.dev.adapter = QStringLiteral("hci0");
        e.dev.bonded = true;
        e.dev.kind = QString::fromLatin1(s.kind);
        e.dev.family = QString::fromLatin1(s.family);
        e.dev.paired = true;
        e.dev.connected = true;
        e.dev.trusted = true;
        e.listed = true;
        m_entries.append(e);
    }
    publish();
}

void MockBluetoothBackend::addTwoPads()
{
    const struct { const char *id; int battery; } pads[] = {{"AA:00:00:00:00:04", 80}, {"AA:00:00:00:00:05", 55}};
    for (const auto &p : pads) {
        if (indexOf(QString::fromLatin1(p.id)) >= 0)
            continue;
        Entry e;
        e.dev.id = QString::fromLatin1(p.id);
        e.dev.name = QStringLiteral("Wireless Controller");
        e.dev.deviceName = e.dev.name;
        e.dev.adapter = QStringLiteral("hci0");
        e.dev.bonded = true;
        e.dev.kind = QStringLiteral("controller");
        e.dev.family = QStringLiteral("playstation");
        e.dev.paired = true;
        e.dev.connected = true;
        e.dev.trusted = true;
        e.dev.battery = p.battery;
        e.listed = true;
        m_entries.append(e);
    }
    publish();
}

void MockBluetoothBackend::reset()
{
    initState();
    publish();
}

// No publishing here: the constructor runs before anybody listens.
void MockBluetoothBackend::initState()
{
    m_holdPairing = false;
    m_gamepads.clear();
    m_heldPairs.clear();
    m_pairCalls = 0;
    m_scanTimer.stop();
    m_pairingTimer.stop();
    m_pairing = QStringLiteral("idle");
    m_pairingScript = QStringLiteral("wait");
    m_inputPresent = true;
    m_pairingStarts = 0;
    m_idleReports = 0;
    m_lastIdleSeconds = -1;
    m_lastIdleTimeout = -1;
    m_lastIdleHold = false;
    m_powered = true;
    m_discovering = false;
    m_scans = 0;
    auto entry = [](const char *id, const char *name, const char *kind, bool paired, bool connected, int battery,
                    int appearAfter, const char *pairResult) {
        Entry e;
        e.dev.id = QString::fromLatin1(id);
        e.dev.name = QString::fromLatin1(name);
        e.dev.deviceName = e.dev.name;
        e.dev.adapter = QStringLiteral("hci0");
        e.dev.kind = QString::fromLatin1(kind);
        e.dev.paired = paired;
        e.dev.bonded = paired;
        e.dev.connected = connected;
        e.dev.trusted = paired;
        e.dev.battery = battery;
        e.appearAfter = appearAfter;
        e.pairResult = QString::fromLatin1(pairResult);
        e.listed = paired;
        return e;
    };
    m_entries = {
        entry("bt-pad-main", "Ruya Pad Pro", "controller", true, true, 80, 0, "ok"),
        entry("bt-pad-old", "Retro Pad", "controller", true, false, -1, 0, "ok"),
        entry("bt-soundbar", "Soundbar", "speaker", true, true, -1, 0, "ok"),
        entry("bt-flaky", "Flaky Pad", "controller", false, false, -1, 1, "pairing-failed"),
        entry("bt-buds", "Sound Buds", "headset", false, false, 90, 1, "ok"),
        entry("bt-sleepy", "Old Headset", "headset", false, false, -1, 1, "timeout"),
        entry("bt-pad-new", "Ruya Pad", "controller", false, false, 64, 2, "ok"),
    };
    // One pad is bonded on a second adapter, like on the Dell (T-336).
    m_entries[indexOf(QStringLiteral("bt-pad-old"))].dev.adapter = QStringLiteral("hci1");
}

int MockBluetoothBackend::indexOf(const QString &id) const
{
    for (int i = 0; i < m_entries.size(); ++i) {
        if (m_entries.at(i).dev.id == id)
            return i;
    }
    return -1;
}

// Asynchronous like the real service. Paired devices come first, otherwise in a stable order;
// nothing is listed while Bluetooth is off.
void MockBluetoothBackend::publish(int delayMs)
{
    QList<BtDevice> list;
    if (m_powered) {
        for (const Entry &e : std::as_const(m_entries)) {
            if (e.listed)
                list.append(e.dev);
        }
        std::stable_partition(list.begin(), list.end(), [](const BtDevice &d) { return d.paired; });
    }
    const bool powered = m_powered;
    const bool discovering = m_discovering;
    const QString pairing = m_pairing;
    const bool inputPresent = m_inputPresent;
    const QList<BtGamepad> pads = gamepadList();
    // Three requests, as on the bus: the state, the list and the pads.
    const quint64 stateRequest = beginStateRequest();
    const quint64 devicesRequest = beginDevicesRequest();
    const quint64 gamepadsRequest = beginGamepadsRequest();
    if (delayMs > 0)
        ++m_pending;
    QTimer::singleShot(delayMs, this, [this, stateRequest, devicesRequest, gamepadsRequest, powered, discovering, pairing, inputPresent, list, pads, delayMs] {
        if (delayMs > 0)
            --m_pending;
        deliverState(stateRequest, powered, discovering, pairing, inputPresent);
        deliverDevices(devicesRequest, list);
        deliverGamepads(gamepadsRequest, pads);
    });
}

// ListGamepads: the pads announced by hand, then the connected controllers of the device list.
QList<BtGamepad> MockBluetoothBackend::gamepadList() const
{
    QList<BtGamepad> pads = m_gamepads;
    for (const Entry &e : m_entries) {
        if (!m_powered || !e.listed || !e.dev.connected || e.dev.kind != QLatin1String("controller"))
            continue;
        const bool known = std::any_of(pads.begin(), pads.end(), [&e](const BtGamepad &p) {
            return p.id.compare(e.dev.id, Qt::CaseInsensitive) == 0;
        });
        if (!known)
            pads.append({e.dev.id, e.dev.name, e.dev.family, QStringLiteral("bluetooth")});
    }
    return pads;
}

void MockBluetoothBackend::answer(const QString &op, const QString &id, const QString &status)
{
    QTimer::singleShot(0, this, [this, op, id, status] { emit finished(op, id, status); });
}
