#include <QQmlContext>
#include <QQmlEngine>
#include <QtQml/qqmlextensionplugin.h>
#include <QtQuickTest>

Q_IMPORT_QML_PLUGIN(RuyaShellPlugin)

class Setup : public QObject
{
    Q_OBJECT

public:
    Setup()
    {
        // Tests always run against the in-memory profiles service.
        qputenv("RUYA_SERVICES", "mock");
    }

public slots:
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        // Set RUYA_SHOTS_DIR to have the screenshot test save PNGs there.
        engine->rootContext()->setContextProperty(QStringLiteral("shotsDir"),
                                                  qEnvironmentVariable("RUYA_SHOTS_DIR"));
    }
};

QUICK_TEST_MAIN_WITH_SETUP(ruyashell, Setup)

#include "tst_main.moc"
