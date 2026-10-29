#pragma once

#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>

// Decides in C++ which keys the shell keeps when an app item has the focus (ADR-002/003).
// An event filter on the window sees a key before the focused item does. While `appItem` has
// active focus, the Guide keys are taken here and reported as signals, so the app never sees
// them; every other key is left alone and reaches the app by normal focus delivery. The volume
// keys are application shortcuts (Shell.qml) and are matched before any key event.
// With no app focused (home, pages, overlays) nothing changes: the Guide key arrives as an
// ordinary key event and the QML handlers deal with it.
class KeyRouter : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QQuickWindow *window READ window WRITE setWindow NOTIFY windowChanged)
    Q_PROPERTY(QQuickItem *appItem READ appItem WRITE setAppItem NOTIFY appItemChanged)

public:
    explicit KeyRouter(QObject *parent = nullptr);

    QQuickWindow *window() const { return m_window; }
    void setWindow(QQuickWindow *window);
    QQuickItem *appItem() const { return m_appItem; }
    void setAppItem(QQuickItem *item);

    // The one place that says which keys are the Guide button. The controller's Guide arrives
    // as HomePage (ruya-inputd); on a keyboard it is Super, left or right (Qt reports the
    // Windows key as Meta on the Windows host). Menu is the context-menu key, not Guide.
    Q_INVOKABLE static bool isGuideKey(int key);

    bool eventFilter(QObject *watched, QEvent *event) override;

signals:
    void windowChanged();
    void appItemChanged();
    // A Guide key taken from the focused app (press, or release; `autoRepeat` for held keys).
    void guidePressed(bool autoRepeat);
    void guideReleased(bool autoRepeat);

private:
    QPointer<QQuickWindow> m_window;
    QPointer<QQuickItem> m_appItem;
};
