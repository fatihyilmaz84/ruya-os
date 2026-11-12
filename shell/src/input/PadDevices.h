#pragma once

#include <QHash>
#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QString>
#include <QTimer>

// The physical pads the emergency reader reads itself (RUY-410, 06 sections 3 and 8): every
// /dev/input/event* node udev tags ID_INPUT_JOYSTICK that the shell may open (logind's ACL gives
// ruya-shell the physical pads; ruya-input's virtual pads are 0600 for the profile user, so they
// never open). While started it looks for new nodes every second, so a pad plugged in or paired
// during the outage works too, and a node that vanishes (read fails with ENODEV) is reported gone.
// ruya-input's own virtual devices (EVIOCGPHYS "ruya-input/...") are never read. It only reads; it never grabs a pad, so a game that has one is not disturbed. Linux only: on
// other hosts start() finds nothing.
class PadDevices : public QObject
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit PadDevices(QObject *parent = nullptr);
    ~PadDevices() override;

    void start();
    // Closes every pad (each is reported gone).
    Q_INVOKABLE void stop();
    // Tests: a pad with no device behind it, so stop() and the destructor have one to close.
    Q_INVOKABLE void mockPad(int id);
    Q_INVOKABLE int padCount() const { return static_cast<int>(m_pads.size()); }
    bool started() const { return m_timer.isActive(); }

signals:
    // A pad's stick range, sent before its first event (ABS_X = 0, ABS_Y = 1).
    void axisRange(int pad, int code, int minimum, int maximum);
    // An EV_KEY or EV_ABS event, as the kernel sent it.
    void padEvent(int pad, int type, int code, int value);
    void gone(int pad);

private:
    struct Pad;

    void scan();
    void open(const QString &path);
    void readFrom(Pad *pad);
    void drop(Pad *pad, bool report = true);
    void closeAll(bool report);
    void resync(Pad *pad);

    QHash<QString, Pad *> m_pads;
    // Nodes that are not ours to read (ruya-input's own virtual devices), not opened again.
    QSet<QString> m_ignored;
    QTimer m_timer;
    int m_nextId = 1;
};
