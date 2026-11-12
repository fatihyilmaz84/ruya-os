#pragma once

#include "PadDevices.h"
#include "PadMapper.h"

#include <QHash>
#include <QObject>
#include <QQmlEngine>
#include <QTimer>

// The compositor's emergency pad reader (RUY-410, 06 section 8, requirement "input failures never
// leave users unable to navigate"). Ruya Input (ruya-inputd) is what turns a pad into navigation
// keys; when org.ruyaos.Input1 has had no owner for graceMs (3 s: a crash loop, a masked unit, a broken
// image) the shell reads the physical pads itself and sends the same keys, until the name has an
// owner again. The restart path (0.5 s) stays the normal recovery; 3 s keeps this out of it.
//   serviceOwned   in: whether the name has an owner (Shell.qml binds Input.serviceOwned)
//   active         out: the fallback is on; the journal says "ruya-shell: input fallback on" / "off"
//   key(key, down) out: a Qt key, one per transition; a key two pads hold goes down with the first
//                  and up with the last; going off, or a pad vanishing, releases what it held
// The keys are the shell's own: Shell.qml hands them to KeyRouter.injectKey, which never gives an
// app anything but the Guide key. Nothing here talks to an app or to ruya-inputd.
class EmergencyReader : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool serviceOwned READ serviceOwned WRITE setServiceOwned NOTIFY serviceOwnedChanged)
    Q_PROPERTY(int graceMs READ graceMs WRITE setGraceMs NOTIFY graceMsChanged)
    // Open the real pads while active (Linux). Off for the mock services and the tests, which feed
    // mockPadEvent instead.
    Q_PROPERTY(bool readDevices READ readDevices WRITE setReadDevices NOTIFY readDevicesChanged)
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    Q_PROPERTY(int padCount READ padCount NOTIFY padCountChanged)

public:
    explicit EmergencyReader(QObject *parent = nullptr);

    bool serviceOwned() const { return m_serviceOwned; }
    void setServiceOwned(bool owned);
    int graceMs() const { return m_grace.interval(); }
    void setGraceMs(int ms);
    bool readDevices() const { return m_readDevices; }
    void setReadDevices(bool read);
    bool active() const { return m_active; }
    int padCount() const { return static_cast<int>(m_pads.size()); }

    // Tests: a pad's event / range / vanishing as the device reader would report them. Only taken
    // while active, like the real ones.
    Q_INVOKABLE void mockPadEvent(int pad, int type, int code, int value);
    Q_INVOKABLE void mockPadRange(int pad, int code, int minimum, int maximum);
    Q_INVOKABLE void mockPadGone(int pad);

signals:
    void serviceOwnedChanged();
    void graceMsChanged();
    void readDevicesChanged();
    void activeChanged();
    void padCountChanged();
    void key(int key, bool pressed);

private:
    void setActive(bool on);
    PadMapper *padFor(int pad);
    void padEvent(int pad, int type, int code, int value);
    void padGone(int pad);
    void emitKeys(const std::vector<PadMapper::KeyEvent> &events);

    bool m_serviceOwned = true;
    bool m_readDevices = true;
    bool m_active = false;
    QTimer m_grace;
    PadDevices m_devices;
    QHash<int, PadMapper *> m_pads;
    // How many pads hold each key.
    QHash<int, int> m_down;
};
