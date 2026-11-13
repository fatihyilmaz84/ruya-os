#include "GameSettings.h"

#include <QFile>
#include <QFileInfo>

namespace {
const char MockGame[] = "org.example.Racer";
const char MockFile[] = ":/qt/qml/RuyaShell/src/gamesettings/mock-game-settings.json";
}

GameSettings::GameSettings(QObject *parent)
    : QObject(parent)
{
    // Like Network and Profiles: the mock unless D-Bus was asked for (Linux default: D-Bus).
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    m_mock = choice == QLatin1String("mock");
#else
    m_mock = choice != QLatin1String("dbus");
#endif
}

GameSettings *GameSettings::create(QQmlEngine *, QJSEngine *)
{
    return new GameSettings;
}

QString GameSettings::mockGameId() const
{
    return QString::fromLatin1(MockGame);
}

QVariantMap GameSettings::toMap(const GameSettingsSchema::Result &result, bool present)
{
    return {
        {QStringLiteral("ok"), result.ok},
        {QStringLiteral("present"), present},
        {QStringLiteral("error"), result.error},
        {QStringLiteral("categories"), result.categories},
        {QStringLiteral("count"), result.count},
    };
}

QVariantMap GameSettings::parse(const QString &json, const QString &language) const
{
    return parseBytes(json.toUtf8(), language);
}

QVariantMap GameSettings::parseBytes(const QByteArray &bytes, const QString &language) const
{
    return toMap(GameSettingsSchema::parse(bytes, language));
}

QVariantMap GameSettings::load(const QString &path, const QString &language) const
{
    GameSettingsSchema::Result failed;
    QFile file(path);
    // The size is looked at before anything is read, and a read never goes past the limit + 1.
    if (!file.exists()) {
        failed.error = QStringLiteral("there is no settings file");
        return toMap(failed, false);
    }
    if (file.size() > GameSettingsSchema::MaxFileBytes) {
        failed.error = QStringLiteral("the file is %1 bytes; at most %2 (64 KiB)")
                           .arg(file.size()).arg(GameSettingsSchema::MaxFileBytes);
        return toMap(failed);
    }
    if (!file.open(QIODevice::ReadOnly)) {
        failed.error = QStringLiteral("the file cannot be read");
        return toMap(failed);
    }
    return toMap(GameSettingsSchema::parse(file.read(GameSettingsSchema::MaxFileBytes + 1), language));
}

QVariantMap GameSettings::forApp(const QString &appId, const QString &language) const
{
    if (m_mock && appId == mockGameId())
        return load(QString::fromLatin1(MockFile), language);
    GameSettingsSchema::Result none;
    return toMap(none, false);
}

QVariantMap GameSettings::mockValues() const
{
    // What Turbo Racer would publish at start: one value for each row that has one. Several differ from
    // the file's defaults, so a panel can tell "published" from "default".
    return {
        {QStringLiteral("graphics.preset"), QStringLiteral("medium")},
        {QStringLiteral("graphics.shadows"), true},
        {QStringLiteral("graphics.raytracing"), false},
        {QStringLiteral("graphics.raytracing_quality"), QStringLiteral("medium")},
        {QStringLiteral("graphics.textures"), QStringLiteral("high")},
        {QStringLiteral("display.fps_limit"), 60},
        {QStringLiteral("display.render_scale"), 85},
        {QStringLiteral("display.brightness"), 0.55},
        {QStringLiteral("controls.vibration"), 0.8},
        {QStringLiteral("controls.invert_y"), false},
        {QStringLiteral("audio.music"), 40},
        {QStringLiteral("audio.engine"), QStringLiteral("realistic")},
        {QStringLiteral("gameplay.difficulty"), QStringLiteral("hard")},
        {QStringLiteral("interface.speedometer"), true},
        {QStringLiteral("accessibility.colour_blind"), QStringLiteral("off")},
        {QStringLiteral("advanced.version"), QStringLiteral("1.4.2 (build 311)")},
    };
}
