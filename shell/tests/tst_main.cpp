#include <QGuiApplication>
#include <QPointer>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QTimer>
#include <QtTest/QTest>
#include <QtQml/qqmlextensionplugin.h>
#include <QtQuickTest>

Q_IMPORT_QML_PLUGIN(RuyaShellPlugin)

// Called from every test's init(): `shots` runs on real windows, and when the desktop takes
// activation away, activeFocus goes false and every later focus assertion fails for a reason
// that has nothing to do with the product. Re-activate, or say plainly that it did not work.
class WindowGuard : public QObject
{
    Q_OBJECT

public:
    explicit WindowGuard(QObject *parent = nullptr)
        : QObject(parent)
    {
        // Name the cause at the moment it happens, so an activeFocus failure that follows is
        // not mistaken for a product bug, and take the activation back right away.
        connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, [this](QWindow *now) {
            if (now) {
                m_last = qobject_cast<QQuickWindow *>(now);
                return;
            }
            if (!m_last || !m_last->isVisible())
                return;
            qWarning("ruya-shell test: TEST WINDOW LOST ACTIVATION (the desktop took focus); "
                     "a focus failure right after this is not a product bug, re-run `shots`");
            QPointer<QQuickWindow> w = m_last;
            QTimer::singleShot(0, this, [w] {
                if (w)
                    w->requestActivate();
            });
        });
    }

    // Returns "" when the test window is active, else the failure message.
    Q_INVOKABLE QString ensureActive()
    {
        QQuickWindow *win = nullptr;
        const auto windows = QGuiApplication::topLevelWindows();
        for (QWindow *w : windows) {
            if (auto *q = qobject_cast<QQuickWindow *>(w); q && q->isVisible()) {
                win = q;
                break;
            }
        }
        if (!win)
            return {};
        if (QGuiApplication::focusWindow() == win)
            return {};
        win->requestActivate();
        if (QTest::qWaitForWindowActive(win, 3000))
            return {};
        return QStringLiteral("test window is not active: the desktop took focus "
                              "(lock screen or another window); re-run `shots`");
    }

private:
    QPointer<QQuickWindow> m_last;
};

class Setup : public QObject
{
    Q_OBJECT

public:
    Setup()
    {
        // Tests always run against the in-memory profiles service.
        qputenv("RUYA_SERVICES", "mock");
        // ...and device settings stay in memory, so tests never touch the real store.
        qputenv("RUYA_SETTINGS_EPHEMERAL", "1");
    }

public slots:
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        // Set RUYA_SHOTS_DIR to have the screenshot test save PNGs there.
        engine->rootContext()->setContextProperty(QStringLiteral("windowGuard"), new WindowGuard(engine));
        engine->rootContext()->setContextProperty(QStringLiteral("shotsDir"),
                                                  qEnvironmentVariable("RUYA_SHOTS_DIR"));
    }
};

QUICK_TEST_MAIN_WITH_SETUP(ruyashell, Setup)

#include "tst_main.moc"
