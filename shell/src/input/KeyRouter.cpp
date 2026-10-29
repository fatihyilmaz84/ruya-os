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

bool KeyRouter::isGuideKey(int key)
{
    return key == Qt::Key_HomePage || key == Qt::Key_Super_L || key == Qt::Key_Super_R || key == Qt::Key_Meta;
}

bool KeyRouter::eventFilter(QObject *watched, QEvent *event)
{
    if (watched != m_window || !m_appItem || !m_appItem->hasActiveFocus())
        return false;
    const QEvent::Type type = event->type();
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
