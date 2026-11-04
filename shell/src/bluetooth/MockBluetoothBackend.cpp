#include "MockBluetoothBackend.h"

#include <algorithm>

MockBluetoothBackend::MockBluetoothBackend(QObject *parent)
    : BluetoothBackend(parent)
{
    m_scanTimer.setSingleShot(true);
    m_scanTimer.setInterval(300);
    connect(&m_scanTimer, &QTimer::timeout, this, &MockBluetoothBackend::endScan);
    initState();
}

void MockBluetoothBackend::refresh()
{
    publish();
}

void MockBluetoothBackend::setPowered(bool on)
{
    if (on != m_powered) {
        m_powered = on;
        m_scanTimer.stop();
        m_discovering = false;
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
        if (e.appearAfter <= m_scans)
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

void MockBluetoothBackend::pair(const QString &id)
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

void MockBluetoothBackend::setBattery(const QString &id, int percent)
{
    const int at = indexOf(id);
    if (at >= 0) {
        m_entries[at].dev.battery = percent;
        publish();
    }
}

void MockBluetoothBackend::reset()
{
    initState();
    publish();
}

// No publishing here: the constructor runs before anybody listens.
void MockBluetoothBackend::initState()
{
    m_scanTimer.stop();
    m_powered = true;
    m_discovering = false;
    m_scans = 0;
    auto entry = [](const char *id, const char *name, const char *kind, bool paired, bool connected, int battery,
                    int appearAfter, const char *pairResult) {
        Entry e;
        e.dev.id = QString::fromLatin1(id);
        e.dev.name = QString::fromLatin1(name);
        e.dev.kind = QString::fromLatin1(kind);
        e.dev.paired = paired;
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
        entry("bt-soundbar", "Soundbar", "audio", true, true, -1, 0, "ok"),
        entry("bt-flaky", "Flaky Pad", "controller", false, false, -1, 1, "pairing-failed"),
        entry("bt-buds", "Sound Buds", "headset", false, false, 90, 1, "ok"),
        entry("bt-sleepy", "Old Headset", "headset", false, false, -1, 1, "timeout"),
        entry("bt-pad-new", "Ruya Pad", "controller", false, false, 64, 2, "ok"),
    };
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
void MockBluetoothBackend::publish()
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
    QTimer::singleShot(0, this, [this, powered, discovering, list] {
        emit stateChanged(powered, discovering);
        emit devicesListed(list);
    });
}

void MockBluetoothBackend::answer(const QString &op, const QString &id, const QString &status)
{
    QTimer::singleShot(0, this, [this, op, id, status] { emit finished(op, id, status); });
}
