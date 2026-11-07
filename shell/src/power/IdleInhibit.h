#pragma once

#include <QHash>
#include <QObject>
#include <QQmlEngine>
#include <QStringList>

// Who keeps the console from idling (T-202): a counted set of named reasons. The compositor adds
// one for every Wayland idle-inhibitor an app holds ("wayland:<n>"); the shell adds its own
// ("job", "update", "audio") from the singletons it can see. IdleClock reads `reasons`; the power
// saving pane shows them, and every change is logged (`ruya-shell: idle inhibit +job`), so a stuck
// inhibitor is findable. Pure bookkeeping: no timers, no platform code.
class IdleInhibit : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The reasons that are held now, sorted, each once.
    Q_PROPERTY(QStringList reasons READ reasons NOTIFY reasonsChanged)
    Q_PROPERTY(bool held READ held NOTIFY reasonsChanged)
    // A debug switch for the VM and the Dell: RUYA_IDLE_DIVISOR=60 makes every power-saving time
    // 60 times shorter (10 minutes become 10 seconds). 1 when unset or not a number from 1 to 3600.
    Q_PROPERTY(qreal timeDivisor READ timeDivisor CONSTANT)

public:
    explicit IdleInhibit(QObject *parent = nullptr);

    static IdleInhibit *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QStringList reasons() const;
    bool held() const { return !m_counts.isEmpty(); }
    qreal timeDivisor() const { return m_divisor; }

    // Acquire and release pair up: a reason is held while its count is above zero. An empty
    // reason, or a release without an acquire, is ignored.
    Q_INVOKABLE void acquire(const QString &reason);
    Q_INVOKABLE void release(const QString &reason);
    // Sets a reason that is simply on or off (the shell's own: it has no count).
    Q_INVOKABLE void setHeld(const QString &reason, bool held);
    Q_INVOKABLE void releaseAll();

signals:
    void reasonsChanged();

private:
    QHash<QString, int> m_counts;
    qreal m_divisor = 1;
};
