#include "EmergencyReader.h"

EmergencyReader::EmergencyReader(QObject *parent)
    : QObject(parent)
    , m_devices(this)
{
    m_grace.setSingleShot(true);
    m_grace.setInterval(3000);
    connect(&m_grace, &QTimer::timeout, this, [this] {
        if (!m_serviceOwned)
            setActive(true);
    });
    connect(&m_devices, &PadDevices::axisRange, this, [this](int pad, int code, int minimum, int maximum) {
        padFor(pad)->setAxisRange(code, minimum, maximum);
    });
    connect(&m_devices, &PadDevices::padEvent, this, &EmergencyReader::padEvent);
    connect(&m_devices, &PadDevices::gone, this, &EmergencyReader::padGone);
}

void EmergencyReader::setServiceOwned(bool owned)
{
    if (m_serviceOwned == owned)
        return;
    m_serviceOwned = owned;
    if (owned) {
        m_grace.stop();
        setActive(false);
    } else if (!m_active) {
        m_grace.start();
    }
    emit serviceOwnedChanged();
}

void EmergencyReader::setGraceMs(int ms)
{
    if (m_grace.interval() == ms)
        return;
    m_grace.setInterval(ms);
    emit graceMsChanged();
}

void EmergencyReader::setReadDevices(bool read)
{
    if (m_readDevices == read)
        return;
    m_readDevices = read;
    if (m_active) {
        if (read)
            m_devices.start();
        else
            m_devices.stop();
    }
    emit readDevicesChanged();
}

void EmergencyReader::setActive(bool on)
{
    if (m_active == on)
        return;
    m_active = on;
    if (on) {
        qInfo("ruya-shell: input fallback on");
        if (m_readDevices)
            m_devices.start();
    } else {
        m_devices.stop();
        // Whatever a pad still held goes up (stop() reports the real ones; a mock pad is released here).
        const QList<int> ids = m_pads.keys();
        for (int id : ids)
            padGone(id);
        qInfo("ruya-shell: input fallback off");
    }
    emit activeChanged();
}

PadMapper *EmergencyReader::padFor(int pad)
{
    PadMapper *&mapper = m_pads[pad];
    if (!mapper) {
        mapper = new PadMapper(this);
        emit padCountChanged();
    }
    return mapper;
}

void EmergencyReader::padEvent(int pad, int type, int code, int value)
{
    if (!m_active)
        return;
    emitKeys(padFor(pad)->handle(type, code, value));
}

void EmergencyReader::padGone(int pad)
{
    PadMapper *mapper = m_pads.take(pad);
    if (!mapper)
        return;
    emitKeys(mapper->releaseEverything());
    mapper->deleteLater();
    emit padCountChanged();
}

// A key goes down when the first pad presses it and up when the last pad lets go.
void EmergencyReader::emitKeys(const std::vector<PadMapper::KeyEvent> &events)
{
    for (const auto &e : events) {
        int &count = m_down[e.key];
        if (e.pressed) {
            if (++count == 1)
                emit key(e.key, true);
        } else if (count > 0 && --count == 0) {
            emit key(e.key, false);
        }
    }
}

void EmergencyReader::mockPadEvent(int pad, int type, int code, int value)
{
    padEvent(pad, type, code, value);
}

void EmergencyReader::mockPadRange(int pad, int code, int minimum, int maximum)
{
    if (m_active)
        padFor(pad)->setAxisRange(code, minimum, maximum);
}

void EmergencyReader::mockPadGone(int pad)
{
    padGone(pad);
}
