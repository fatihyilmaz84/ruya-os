#include <QCommandLineParser>
#include <QFile>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>

#include <cstdio>

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
    parser.process(app);

    QQmlApplicationEngine engine;
    engine.setInitialProperties({
        {QStringLiteral("version"), imageVersion()},
        {QStringLiteral("windowed"), parser.isSet(windowed)},
    });
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("RuyaShell", "Main");

    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().value(0));
    if (!window)
        return 1;

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
