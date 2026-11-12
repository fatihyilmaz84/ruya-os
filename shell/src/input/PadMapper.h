#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

#include <array>
#include <vector>

// One physical pad's evdev events turned into the shell's navigation keys (RUY-410): the emergency
// reader's copy of ruya-inputd's Phase 0 table (services/ruya-inputd/src/mapping.rs, 06 section 8)
// for D-pad, left stick, south, east, start and guide. Free of the kernel's headers (the codes are
// plain numbers), so it is tested on any host.
//   D-pad (hat axes or the BTN_DPAD buttons) and left stick  Up Down Left Right
//   south (A)  Return    east (B)  Escape    start  Menu    guide  HomePage
// The stick presses at 60 % of its half range and lets go below 35 %, so it does not chatter at
// the edge. A key several sources hold (the hat and the stick both say Down) goes down once and up
// when the last source lets go. A button released that was never seen pressed (the pad was opened
// with it held) holds nothing and takes nothing away.
class PadMapper : public QObject
{
    Q_OBJECT
    QML_ELEMENT

public:
    struct KeyEvent
    {
        int key;      // Qt::Key
        bool pressed;
    };

    // The kernel's numbers (linux/input-event-codes.h).
    static constexpr int EvKey = 0x01;
    static constexpr int EvAbs = 0x03;
    static constexpr int AbsX = 0x00;
    static constexpr int AbsY = 0x01;
    static constexpr int AbsHat0X = 0x10;
    static constexpr int AbsHat0Y = 0x11;
    static constexpr int BtnSouth = 0x130;
    static constexpr int BtnEast = 0x131;
    static constexpr int BtnStart = 0x13b;
    static constexpr int BtnMode = 0x13c;
    static constexpr int BtnDpadUp = 0x220;
    static constexpr int BtnDpadDown = 0x221;
    static constexpr int BtnDpadLeft = 0x222;
    static constexpr int BtnDpadRight = 0x223;

    explicit PadMapper(QObject *parent = nullptr);

    // The raw range of an axis (EVIOCGABS); until set a stick axis is taken as -32768..32767.
    Q_INVOKABLE void setAxisRange(int code, int minimum, int maximum);
    // One evdev event (type EV_KEY or EV_ABS) as [{ key, pressed }], in order. Other events and
    // key repeats (value 2) give [].
    Q_INVOKABLE QVariantList feed(int type, int code, int value);
    // The pad is gone: a release for every key it holds, then it holds nothing.
    Q_INVOKABLE QVariantList releaseAll();
    // The Qt keys held now.
    Q_INVOKABLE QVariantList heldKeys() const;

    std::vector<KeyEvent> handle(int type, int code, int value);
    std::vector<KeyEvent> releaseEverything();

private:
    enum Nav { Up, Down, Left, Right, Accept, Back, Menu, Guide, NavCount };

    void press(Nav key, std::vector<KeyEvent> &out);
    void release(Nav key, std::vector<KeyEvent> &out);
    void move(int &slot, int to, std::vector<KeyEvent> &out);
    void button(Nav key, bool pressed, std::vector<KeyEvent> &out);
    void hat(int axis, int value, std::vector<KeyEvent> &out);
    void stick(int axis, int value, std::vector<KeyEvent> &out);

    // The key each source holds now, -1 for none.
    std::array<int, 2> m_hat{ { -1, -1 } };
    std::array<int, 2> m_stick{ { -1, -1 } };
    std::array<bool, NavCount> m_buttons{};
    std::array<int, NavCount> m_held{};
    std::array<int, 2> m_min{ { -32768, -32768 } };
    std::array<int, 2> m_max{ { 32767, 32767 } };
};
