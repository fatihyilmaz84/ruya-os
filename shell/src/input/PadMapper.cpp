#include "PadMapper.h"

#include <QVariantMap>

#include <cmath>

namespace {
constexpr double StickPress = 0.6;
constexpr double StickRelease = 0.35;

constexpr int KeyOf[8] = { Qt::Key_Up,   Qt::Key_Down, Qt::Key_Left, Qt::Key_Right,
                           Qt::Key_Return, Qt::Key_Escape, Qt::Key_Menu, Qt::Key_HomePage };

QVariantList toList(const std::vector<PadMapper::KeyEvent> &events)
{
    QVariantList out;
    for (const auto &e : events)
        out.append(QVariantMap{ { QStringLiteral("key"), e.key }, { QStringLiteral("pressed"), e.pressed } });
    return out;
}
} // namespace

PadMapper::PadMapper(QObject *parent)
    : QObject(parent)
{
}

void PadMapper::setAxisRange(int code, int minimum, int maximum)
{
    if (code != AbsX && code != AbsY)
        return;
    m_min[code] = minimum;
    m_max[code] = maximum;
}

QVariantList PadMapper::feed(int type, int code, int value)
{
    return toList(handle(type, code, value));
}

QVariantList PadMapper::releaseAll()
{
    return toList(releaseEverything());
}

QVariantList PadMapper::heldKeys() const
{
    QVariantList out;
    for (int i = 0; i < NavCount; ++i) {
        if (m_held[i] > 0)
            out.append(KeyOf[i]);
    }
    return out;
}

void PadMapper::press(Nav key, std::vector<KeyEvent> &out)
{
    if (++m_held[key] == 1)
        out.push_back({ KeyOf[key], true });
}

void PadMapper::release(Nav key, std::vector<KeyEvent> &out)
{
    if (m_held[key] > 0 && --m_held[key] == 0)
        out.push_back({ KeyOf[key], false });
}

// A source (a hat axis, a stick axis) lets go of the key it held and takes another, if any.
void PadMapper::move(int &slot, int to, std::vector<KeyEvent> &out)
{
    if (slot == to)
        return;
    if (slot >= 0)
        release(static_cast<Nav>(slot), out);
    if (to >= 0)
        press(static_cast<Nav>(to), out);
    slot = to;
}

void PadMapper::button(Nav key, bool pressed, std::vector<KeyEvent> &out)
{
    if (m_buttons[key] == pressed)
        return; // a repeated press is no second hold; a release never seen pressed holds nothing
    m_buttons[key] = pressed;
    if (pressed)
        press(key, out);
    else
        release(key, out);
}

void PadMapper::hat(int axis, int value, std::vector<KeyEvent> &out)
{
    const int to = value == 0 ? -1 : axis == 0 ? (value < 0 ? Left : Right) : (value < 0 ? Up : Down);
    move(m_hat[axis], to, out);
}

void PadMapper::stick(int axis, int value, std::vector<KeyEvent> &out)
{
    const double half = (static_cast<double>(m_max[axis]) - m_min[axis]) / 2.0;
    if (half <= 0.0)
        return;
    const double deflection = (value - (m_min[axis] + half)) / half;
    const bool held = m_stick[axis] >= 0;
    int to = -1;
    if (std::fabs(deflection) >= StickPress || (held && std::fabs(deflection) > StickRelease))
        to = axis == 0 ? (deflection < 0 ? Left : Right) : (deflection < 0 ? Up : Down);
    move(m_stick[axis], to, out);
}

std::vector<PadMapper::KeyEvent> PadMapper::handle(int type, int code, int value)
{
    std::vector<KeyEvent> out;
    if (type == EvKey) {
        if (value == 2)
            return out;
        const bool down = value != 0;
        switch (code) {
        case BtnSouth: button(Accept, down, out); break;
        case BtnEast: button(Back, down, out); break;
        case BtnStart: button(Menu, down, out); break;
        case BtnMode: button(Guide, down, out); break;
        case BtnDpadUp: button(Up, down, out); break;
        case BtnDpadDown: button(Down, down, out); break;
        case BtnDpadLeft: button(Left, down, out); break;
        case BtnDpadRight: button(Right, down, out); break;
        default: break;
        }
    } else if (type == EvAbs) {
        switch (code) {
        case AbsHat0X: hat(0, value, out); break;
        case AbsHat0Y: hat(1, value, out); break;
        case AbsX: stick(0, value, out); break;
        case AbsY: stick(1, value, out); break;
        default: break;
        }
    }
    return out;
}

std::vector<PadMapper::KeyEvent> PadMapper::releaseEverything()
{
    std::vector<KeyEvent> out;
    for (int i = 0; i < NavCount; ++i) {
        if (m_held[i] > 0)
            out.push_back({ KeyOf[i], false });
    }
    m_hat = { { -1, -1 } };
    m_stick = { { -1, -1 } };
    m_buttons = {};
    m_held = {};
    return out;
}
