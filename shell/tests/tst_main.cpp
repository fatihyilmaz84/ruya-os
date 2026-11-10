#include "DeviceSettings.h"

#include <QFontDatabase>
#include <QImage>
#include <QLinearGradient>
#include <QPainter>
#include <QGuiApplication>
#include <QPointer>
#include <QSettings>
#include <QTemporaryDir>
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
        // A window that is not back within a second and a half fails the test that is running
        // (T-429), in these words, instead of a random activeFocus line later.
        m_lostTimer.setSingleShot(true);
        m_lostTimer.setInterval(1500);
        connect(&m_lostTimer, &QTimer::timeout, this, [this] {
            if (!m_last || !m_last->isVisible())
                return;                 // the window itself went away: not the desktop
            if (!m_simulated && QGuiApplication::focusWindow())
                return;
            QTest::qFail("TEST WINDOW LOST ACTIVATION: the desktop took focus mid-test and the "
                         "window did not get it back (lock screen or another window); this is "
                         "not a product bug, re-run `shots`",
                         __FILE__, __LINE__);
        });
        connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, [this](QWindow *now) {
            if (now) {
                m_last = qobject_cast<QQuickWindow *>(now);
                if (!m_simulated)
                    m_lostTimer.stop();
                return;
            }
            handleLoss(true);
        });
    }

    Q_PROPERTY(bool fixtureEnabled READ fixtureEnabled CONSTANT)
public:
    bool fixtureEnabled() const { return qEnvironmentVariableIntValue("RUYA_ACTIVATION_FIXTURE") != 0; }

    // For the fixture (tst_window_lost_fixture.qml): behave as if the desktop took the focus and
    // never gave it back, without needing a real desktop.
    Q_INVOKABLE void simulateLoss()
    {
        if (m_last)
            m_simulated = true;
        handleLoss(false);
    }
    Q_INVOKABLE void endSimulation()
    {
        m_simulated = false;
        m_lostTimer.stop();
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
    void handleLoss(bool reactivate)
    {
        if (!m_last || !m_last->isVisible())
            return;
        qWarning("ruya-shell test: TEST WINDOW LOST ACTIVATION (the desktop took focus); "
                 "a focus failure right after this is not a product bug, re-run `shots`");
        m_lostTimer.start();
        if (!reactivate)
            return;
        QPointer<QQuickWindow> w = m_last;
        QTimer::singleShot(0, this, [w] {
            if (w)
                w->requestActivate();
        });
    }

    QPointer<QQuickWindow> m_last;
    QTimer m_lostTimer;
    bool m_simulated = false;
};

// Pictures for the art glow (T-281): solid-ish 160 x 90 pictures in a temporary directory, so no
// binary is committed. red, blue, green, white and dark are a gentle diagonal gradient of one
// colour; redblue is red on the left half and blue on the right; grey and pastel exercise the
// sampler's limits. Exposed to the tests as `artFixtures` (a path); the mock library and store take
// the first six as card art (MockArt.h).
static QString writeArtFixtures(const QTemporaryDir &dir)
{
    if (!dir.isValid())
        return {};
    auto gradient = [&](const char *name, const QColor &from, const QColor &to) {
        QImage image(160, 90, QImage::Format_RGB32);
        QPainter p(&image);
        QLinearGradient g(0, 0, 160, 90);
        g.setColorAt(0, from);
        g.setColorAt(1, to);
        p.fillRect(image.rect(), g);
        p.end();
        image.save(dir.filePath(QString::fromLatin1(name) + QStringLiteral(".png")));
    };
    gradient("red", QColor(235, 40, 40), QColor(140, 15, 20));
    gradient("blue", QColor(50, 90, 235), QColor(20, 40, 140));
    gradient("green", QColor(50, 200, 80), QColor(20, 120, 50));
    gradient("white", QColor(255, 255, 255), QColor(235, 235, 240));
    gradient("dark", QColor(16, 16, 24), QColor(6, 6, 10));
    gradient("grey", QColor(150, 150, 150), QColor(110, 110, 110));
    gradient("pastel", QColor(255, 225, 230), QColor(245, 205, 215));
    gradient("darkred", QColor(40, 4, 4), QColor(20, 2, 2));
    QImage two(160, 90, QImage::Format_RGB32);
    QPainter p(&two);
    p.fillRect(0, 0, 80, 90, QColor(230, 30, 30));
    p.fillRect(80, 0, 80, 90, QColor(40, 80, 230));
    p.end();
    two.save(dir.filePath(QStringLiteral("redblue.png")));
    return dir.path();
}

// DeviceSettings.theme survives a restart (T-209): a second instance on the same store reads what
// the first wrote, and a stored value that is not a theme falls back to the default. Runs against an
// ini file in a temporary directory (DeviceSettings(iniPath)), never the developer's real store.
// Returns "" or what went wrong; the QML test tst_themes.qml asserts it (`themePersistence`).
static QString checkThemePersistence()
{
    QTemporaryDir dir;
    if (!dir.isValid())
        return QStringLiteral("no temporary directory");
    const QString path = dir.filePath(QStringLiteral("shell.ini"));
    QString problem;
    {
        DeviceSettings first(path);
        if (first.theme() != QLatin1String("dreamglass"))
            problem = QStringLiteral("the default theme is not dreamglass: ") + first.theme();
        first.setTheme(QStringLiteral("ember"));
    }
    {
        DeviceSettings second(path);
        if (second.theme() != QLatin1String("ember"))
            problem += QStringLiteral(" a restart lost the theme: ") + second.theme();
    }
    {
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("display/theme"), QStringLiteral("nonsense"));
    }
    {
        DeviceSettings third(path);
        if (third.theme() != QLatin1String("dreamglass"))
            problem += QStringLiteral(" a stored non-theme was accepted: ") + third.theme();
    }
    return problem.trimmed();
}

// DeviceSettings.wallpaper and wallpaperDim survive a restart (T-208), and a stored value that is not
// a wallpaper id (a path, a value out of range) falls back. Same hermetic store as above.
// Returns "" or what went wrong; tst_wallpaper.qml asserts it (`wallpaperPersistence`).
static QString checkWallpaperPersistence()
{
    QTemporaryDir dir;
    if (!dir.isValid())
        return QStringLiteral("no temporary directory");
    const QString path = dir.filePath(QStringLiteral("shell.ini"));
    QString problem;
    {
        DeviceSettings first(path);
        if (!first.wallpaper().isEmpty() || !qFuzzyCompare(first.wallpaperDim(), 0.2))
            problem = QStringLiteral("the defaults are not the default look and 20 %");
        first.setWallpaper(QStringLiteral("aurora"));
        first.setWallpaperDim(0.35);
    }
    {
        DeviceSettings second(path);
        if (second.wallpaper() != QLatin1String("aurora") || !qFuzzyCompare(second.wallpaperDim(), 0.35))
            problem += QStringLiteral(" a restart lost the wallpaper: ") + second.wallpaper();
    }
    {
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("display/wallpaper"), QStringLiteral("../../etc/passwd"));
        raw.setValue(QStringLiteral("display/wallpaperDim"), 0.9);
    }
    {
        DeviceSettings third(path);
        if (!third.wallpaper().isEmpty() || !qFuzzyCompare(third.wallpaperDim(), 0.2))
            problem += QStringLiteral(" a stored bad wallpaper was accepted: ") + third.wallpaper();
    }
    return problem.trimmed();
}

// DeviceSettings.pauseGamesInHub survives a restart (T-457): on by default, off stays off. Same hermetic
// store as above. Returns "" or what went wrong; tst_hub_pause.qml asserts it (`pausePersistence`).
static QString checkPausePersistence()
{
    QTemporaryDir dir;
    if (!dir.isValid())
        return QStringLiteral("no temporary directory");
    const QString path = dir.filePath(QStringLiteral("shell.ini"));
    QString problem;
    {
        DeviceSettings first(path);
        if (!first.pauseGamesInHub())
            problem = QStringLiteral("the pause is not on by default");
        first.setPauseGamesInHub(false);
    }
    {
        DeviceSettings second(path);
        if (second.pauseGamesInHub())
            problem += QStringLiteral(" a restart lost the switched-off pause");
        second.setPauseGamesInHub(true);
    }
    {
        DeviceSettings third(path);
        if (!third.pauseGamesInHub())
            problem += QStringLiteral(" a restart lost the switched-on pause");
    }
    return problem.trimmed();
}

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
        // ...and the mock store installs in milliseconds.
        qputenv("RUYA_MOCK_FAST", "1");
        // ...and the mock USB stick is only plugged in by the tests that want it.
        qputenv("RUYA_MOCK_NO_STICK", "1");
        // ...and the ambient loop is given no file, so a test run makes no noise (T-227).
        qputenv("RUYA_SOUNDS_DRY", "1");
        // ...and a test may read a resource of the module with XMLHttpRequest (tst_glide.qml checks
        // that the liquid pill's compiled shader is in it).
        qputenv("QML_XHR_ALLOW_FILE_READ", "1");
    }

public slots:
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        // The icon fonts, as main.cpp loads them. Setup is constructed before the
        // QGuiApplication exists, so this is the first place fonts can be registered.
        static bool fontsLoaded = false;
        if (!fontsLoaded) {
            fontsLoaded = true;
            for (const char *file : {"MaterialSymbolsRounded.ttf", "MaterialSymbolsRoundedFilled.ttf"}) {
                const QString path = QStringLiteral(":/qt/qml/RuyaShell/fonts/") + QLatin1String(file);
                if (QFontDatabase::addApplicationFont(path) < 0)
                    qWarning("ruya-shell test: cannot load font %s", file);
            }
            for (const char *file : {"Inter-Regular.ttf", "Inter-Light.ttf", "Inter-SemiBold.ttf", "Inter-Bold.ttf"}) {
                const QString path = QStringLiteral(":/qt/qml/RuyaShell/fonts/") + QLatin1String(file);
                if (QFontDatabase::addApplicationFont(path) < 0)
                    qWarning("ruya-shell test: cannot load font %s", file);
            }
            QGuiApplication::setFont(QFont(QStringLiteral("Inter")));
        }
        // Set RUYA_SHOTS_DIR to have the screenshot test save PNGs there.
        static const QString persistence = checkThemePersistence();
        engine->rootContext()->setContextProperty(QStringLiteral("themePersistence"), persistence);
        static const QString wallpaperCheck = checkWallpaperPersistence();
        engine->rootContext()->setContextProperty(QStringLiteral("wallpaperPersistence"), wallpaperCheck);
        static const QString pauseCheck = checkPausePersistence();
        engine->rootContext()->setContextProperty(QStringLiteral("pausePersistence"), pauseCheck);
        static QTemporaryDir artDir;
        static const QString artPath = writeArtFixtures(artDir);
        engine->rootContext()->setContextProperty(QStringLiteral("artFixtures"), artPath);
        engine->rootContext()->setContextProperty(QStringLiteral("windowGuard"), new WindowGuard(engine));
        engine->rootContext()->setContextProperty(QStringLiteral("shotsDir"),
                                                  qEnvironmentVariable("RUYA_SHOTS_DIR"));
    }
};

QUICK_TEST_MAIN_WITH_SETUP(ruyashell, Setup)

#include "tst_main.moc"
