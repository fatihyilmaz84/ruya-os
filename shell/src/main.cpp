#include <QCommandLineParser>
#include <QFile>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QtQml/qqmlextensionplugin.h>

#include <cstdio>

Q_IMPORT_QML_PLUGIN(RuyaShellPlugin)

// Written into the image at build time (image/Containerfile); lets update/rollback tests
// see which deployment is running.
static QString imageVersion()
{
    QFile file(QStringLiteral("/usr/lib/ruyaos/version"));
    if (file.open(QIODevice::ReadOnly))
        return QString::fromUtf8(file.readAll()).trimmed();
    return QStringLiteral("dev");
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("ruya-shell"));
    app.setOrganizationDomain(QStringLiteral("ruyaos.org"));

    QCommandLineParser parser;
    parser.addHelpOption();
    const QCommandLineOption windowed(QStringLiteral("windowed"),
                                      QStringLiteral("Run in a window instead of fullscreen (development)."));
    parser.addOption(windowed);
    const QCommandLineOption mockServices(QStringLiteral("mock-services"),
                                          QStringLiteral("Use in-memory system services instead of D-Bus."));
    parser.addOption(mockServices);
    const QCommandLineOption reducedMotion(QStringLiteral("reduced-motion"),
                                           QStringLiteral("Force reduced motion for this session (not saved)."));
    parser.addOption(reducedMotion);
    const QCommandLineOption effects(QStringLiteral("effects"),
                                     QStringLiteral("Force the effects quality tier for this session (not saved)."),
                                     QStringLiteral("high|balanced|performance"));
    parser.addOption(effects);
    const QCommandLineOption reverse(QStringLiteral("reverse"),
                                     QStringLiteral("Lay the UI out right-to-left (RTL readiness check)."));
    parser.addOption(reverse);
    const QCommandLineOption load(QStringLiteral("load"),
                                  QStringLiteral("Load this QML file instead of the shell (spikes, development)."),
                                  QStringLiteral("file"));
    parser.addOption(load);
    parser.process(app);
    if (parser.isSet(reverse))
        QGuiApplication::setLayoutDirection(Qt::RightToLeft);
    if (parser.isSet(mockServices))
        qputenv("RUYA_SERVICES", "mock"); // read when the Profiles singleton is created
    // Read when the DeviceSettings singleton is created; session-only, never persisted.
    if (parser.isSet(reducedMotion))
        qputenv("RUYA_FORCE_REDUCED_MOTION", "1");
    if (parser.isSet(effects))
        qputenv("RUYA_FORCE_EFFECTS", parser.value(effects).toUtf8());

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    if (parser.isSet(load)) {
        // A file outside the RuyaShell module (shell/spike, T-123); it can still import RuyaShell.
        engine.load(parser.value(load));
    } else {
        engine.setInitialProperties({
            {QStringLiteral("version"), imageVersion()},
            {QStringLiteral("windowed"), parser.isSet(windowed)},
        });
        engine.loadFromModule("RuyaShell", "Main");
    }

    QObject *root = engine.rootObjects().value(0);
    if (!root)
        return 1;
    // The root is the window, or (a compositor) owns one.
    auto *window = qobject_cast<QQuickWindow *>(root);
    if (!window)
        window = root->findChild<QQuickWindow *>();
    if (!window)
        return app.exec();

    // The greenboot health check and the CI boot test wait for this line: it means the
    // first frame was actually presented, not just that the process started.
    QObject::connect(
        window, &QQuickWindow::frameSwapped, window,
        [] {
            std::fputs("ruya-shell: ready\n", stdout);
            std::fflush(stdout);
        },
        Qt::SingleShotConnection);

    return app.exec();
}
