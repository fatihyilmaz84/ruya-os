#pragma once

#include <QObject>
#include <QPointer>
#include <QSet>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>

// Decides in C++ which keys the shell keeps when an app item has the focus (ADR-002/003).
// An event filter on the window sees a key before the focused item does. While `appItem` or an
// item inside it has active focus, the Guide keys are taken here and reported as signals, so the app never sees
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
    // While true (the screen saver or the dark screen is up, T-202) every key, mouse, touch and
    // wheel event is reported through activity() and then eaten: nothing below sees the press that
    // wakes the console, nor its release.
    Q_PROPERTY(bool swallowInput READ swallowInput WRITE setSwallowInput NOTIFY swallowInputChanged)

public:
    explicit KeyRouter(QObject *parent = nullptr);

    QQuickWindow *window() const { return m_window; }
    void setWindow(QQuickWindow *window);
    QQuickItem *appItem() const { return m_appItem; }
    void setAppItem(QQuickItem *item);
    bool swallowInput() const { return m_swallowInput; }
    void setSwallowInput(bool swallow);

    // The one place that says which keys are the Guide button. The controller's Guide arrives
    // as HomePage (ruya-inputd); on a keyboard it is Super, left or right (Qt reports the
    // Windows key as Meta on the Windows host). Menu is the context-menu key, not Guide.
    Q_INVOKABLE static bool isGuideKey(int key);

    bool eventFilter(QObject *watched, QEvent *event) override;

signals:
    void windowChanged();
    void appItemChanged();
    void swallowInputChanged();
    // A Guide key taken from the focused app (press, or release; `autoRepeat` for held keys).
    void guidePressed(bool autoRepeat);
    void guideReleased(bool autoRepeat);
    // Any key, mouse or touch input reached the window (for the idle rule of the update service;
    // the receiver limits how often it acts on it).
    void activity();

private:
    bool appHasFocus() const;

    QPointer<QQuickWindow> m_window;
    QPointer<QQuickItem> m_appItem;
    bool m_swallowInput = false;
    // Keys and mouse buttons whose press was eaten: their release is eaten too.
    QSet<int> m_eatenKeys;
    bool m_eatenMouse = false;
};
