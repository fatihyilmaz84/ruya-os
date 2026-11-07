#include "KeyRouter.h"

#include <QKeyEvent>

KeyRouter::KeyRouter(QObject *parent)
    : QObject(parent)
{
}

void KeyRouter::setWindow(QQuickWindow *window)
{
    if (m_window == window)
        return;
    if (m_window)
        m_window->removeEventFilter(this);
    m_window = window;
    if (m_window)
        m_window->installEventFilter(this);
    emit windowChanged();
}

void KeyRouter::setAppItem(QQuickItem *item)
{
    if (m_appItem == item)
        return;
    m_appItem = item;
    emit appItemChanged();
}

void KeyRouter::setSwallowInput(bool swallow)
{
    if (m_swallowInput == swallow)
        return;
    m_swallowInput = swallow;
    emit swallowInputChanged();
}

bool KeyRouter::isGuideKey(int key)
{
    return key == Qt::Key_HomePage || key == Qt::Key_Super_L || key == Qt::Key_Super_R || key == Qt::Key_Meta;
}

// The app item itself, or an item inside it (a compositor surface item may hand the focus to a
// child, and a plain Item is not a focus scope, so hasActiveFocus() alone would miss it).
bool KeyRouter::appHasFocus() const
{
    if (!m_window || !m_appItem)
        return false;
    QQuickItem *focused = m_window->activeFocusItem();
    return focused && (focused == m_appItem || m_appItem->isAncestorOf(focused));
}

bool KeyRouter::eventFilter(QObject *watched, QEvent *event)
{
    if (watched != m_window)
        return false;
    const QEvent::Type type = event->type();
    // Decided before activity() is emitted: the receiver wakes the console, which clears the flag.
    const bool eat = m_swallowInput;
    if (type == QEvent::KeyPress && m_eatenKeys.contains(static_cast<QKeyEvent *>(event)->key()))
        return true; // the held key that woke the console keeps repeating: still not for the page
    if (type == QEvent::KeyRelease) {
        auto *key = static_cast<QKeyEvent *>(event);
        if (m_eatenKeys.remove(key->key()))
            return true;
    } else if (type == QEvent::MouseButtonRelease && m_eatenMouse) {
        m_eatenMouse = false;
        return true;
    }
    switch (type) {
    case QEvent::KeyPress:
    case QEvent::MouseButtonPress:
    case QEvent::MouseMove:
    case QEvent::TouchBegin:
    case QEvent::Wheel:
        emit activity();
        break;
    default:
        break;
    }
    if (eat) {
        switch (type) {
        case QEvent::KeyPress:
            m_eatenKeys.insert(static_cast<QKeyEvent *>(event)->key());
            return true;
        case QEvent::MouseButtonPress:
            m_eatenMouse = true;
            return true;
        case QEvent::MouseMove:
        case QEvent::TouchBegin:
        case QEvent::TouchUpdate:
        case QEvent::TouchEnd:
        case QEvent::Wheel:
            return true;
        default:
            break;
        }
    }
    if (!appHasFocus())
        return false;
    if (type != QEvent::KeyPress && type != QEvent::KeyRelease)
        return false;
    auto *key = static_cast<QKeyEvent *>(event);
    if (!isGuideKey(key->key()))
        return false;
    if (type == QEvent::KeyPress)
        emit guidePressed(key->isAutoRepeat());
    else
        emit guideReleased(key->isAutoRepeat());
    return true;
}
