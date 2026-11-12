#include "DeviceSettings.h"

#include <QCoreApplication>
#include <QLocale>
#include <QMetaObject>
#include <QRegularExpression>
#include <QtMath>

namespace {
constexpr qreal kMaxOverscan = 0.10;
constexpr qreal kMaxWallpaperDim = 0.60;
}

DeviceSettings::DeviceSettings(bool persistent, QObject *parent)
    : QObject(parent)
{
    if (persistent)
        m_store = std::make_unique<QSettings>(QStringLiteral("ruyaos"), QStringLiteral("shell"));
    init();
}

DeviceSettings::DeviceSettings(const QString &iniPath, QObject *parent)
    : QObject(parent)
    , m_store(std::make_unique<QSettings>(iniPath, QSettings::IniFormat))
{
    init();
}

void DeviceSettings::init()
{
    if (m_store) {
        m_reducedMotion = m_store->value(QStringLiteral("display/reducedMotion"), false).toBool();
        const QString quality = m_store->value(QStringLiteral("display/effectsQuality"), m_quality).toString();
        if (isValidQuality(quality))
            m_quality = quality;
        bool ok = false;
        const qreal overscan = m_store->value(QStringLiteral("display/overscan"), m_overscan).toReal(&ok);
        if (ok && overscan >= 0.0 && overscan <= kMaxOverscan)
            m_overscan = overscan;
        const QString wallpaper = m_store->value(QStringLiteral("display/wallpaper")).toString();
        if (isValidWallpaper(wallpaper))
            m_wallpaper = wallpaper;
        const qreal dim = m_store->value(QStringLiteral("display/wallpaperDim"), m_wallpaperDim).toReal(&ok);
        if (ok && dim >= 0.0 && dim <= kMaxWallpaperDim)
            m_wallpaperDim = dim;
        const QString theme = m_store->value(QStringLiteral("display/theme"), m_theme).toString();
        if (isValidTheme(theme))
            m_theme = theme;
        const QString soundTheme = m_store->value(QStringLiteral("sound/theme"), m_soundTheme).toString();
        if (isValidSoundTheme(soundTheme))
            m_soundTheme = soundTheme;
        m_ambientSound = m_store->value(QStringLiteral("sound/ambient"), m_ambientSound).toBool();
        const auto minutes = [this](const char *key, int fallback) {
            const int value = m_store->value(QString::fromLatin1(key), fallback).toInt();
            return isValidMinutes(value) ? value : fallback;
        };
        m_saverMinutes = minutes("power/saverMinutes", m_saverMinutes);
        m_screenOffMinutes = minutes("power/screenOffMinutes", m_screenOffMinutes);
        m_sleepMinutes = minutes("power/sleepMinutes", m_sleepMinutes);
        m_padIdleMinutes = minutes("power/padIdleMinutes", m_padIdleMinutes);
        const int interval = m_store->value(QStringLiteral("hub/performanceIntervalMs"), m_performanceIntervalMs).toInt();
        if (isValidPerformanceInterval(interval))
            m_performanceIntervalMs = interval;
        m_pauseGamesInHub = m_store->value(QStringLiteral("hub/pauseGames"), m_pauseGamesInHub).toBool();
        m_store->beginGroup(QStringLiteral("hub/performanceOverlay"));
        for (const QString &id : m_store->childKeys()) {
            if (isValidProfileKey(id) && m_store->value(id).toBool())
                m_overlayProfiles.insert(id, true);
        }
        m_store->endGroup();
        const QString language = m_store->value(QStringLiteral("general/language")).toString();
        if (isValidLanguage(language)) {
            m_language = language;
        } else {
            const QString system = QLocale::system().name().section(QLatin1Char('_'), 0, 0);
            if (isValidLanguage(system))
                m_language = system;
        }
    }

    if (qEnvironmentVariableIntValue("RUYA_FORCE_REDUCED_MOTION") != 0)
        m_forcedMotion = true;
    const QString forced = qEnvironmentVariable("RUYA_FORCE_EFFECTS");
    if (!forced.isEmpty()) {
        if (isValidQuality(forced))
            m_forcedQuality = forced;
        else
            qWarning("ruya-shell: ignoring invalid --effects value '%s'", qPrintable(forced));
    }
}

DeviceSettings::~DeviceSettings()
{
    QCoreApplication::removeTranslator(&m_translator);
}

DeviceSettings *DeviceSettings::create(QQmlEngine *qmlEngine, QJSEngine *)
{
    auto *settings = new DeviceSettings(qEnvironmentVariableIntValue("RUYA_SETTINGS_EPHEMERAL") == 0);
    settings->m_engine = qmlEngine;
    settings->applyLanguage(false);
    // Bindings evaluated before this singleton existed used the source (English) strings.
    if (qmlEngine)
        QMetaObject::invokeMethod(qmlEngine, [qmlEngine] { qmlEngine->retranslate(); }, Qt::QueuedConnection);
    return settings;
}

// English is the source language; its .qm only adds the plural forms, so it is installed too.
void DeviceSettings::applyLanguage(bool retranslate)
{
    // Numbers and sizes (Storage::formatBytes) follow the shell language, not the system's.
    QLocale::setDefault(QLocale(m_language));
    QCoreApplication::removeTranslator(&m_translator);
    if (!m_translator.load(QStringLiteral("ruyashell_%1").arg(m_language), QStringLiteral(":/i18n")))
        qWarning("ruya-shell: no translation for '%s'", qPrintable(m_language));
    else
        QCoreApplication::installTranslator(&m_translator);
    if (retranslate && m_engine)
        m_engine->retranslate();
}

bool DeviceSettings::isValidQuality(const QString &value)
{
    return value == QLatin1String("high") || value == QLatin1String("balanced")
        || value == QLatin1String("performance");
}

bool DeviceSettings::isValidLanguage(const QString &value)
{
    return value == QLatin1String("en") || value == QLatin1String("tr");
}

bool DeviceSettings::isValidWallpaper(const QString &value)
{
    if (value.isEmpty())
        return true;
    static const QRegularExpression bundled(QStringLiteral("^[a-z0-9-]{1,32}$"));
    static const QRegularExpression user(QStringLiteral("^user:[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"));
    return bundled.match(value).hasMatch() || user.match(value).hasMatch();
}

bool DeviceSettings::isValidSoundTheme(const QString &value)
{
    static const QRegularExpression bundled(QStringLiteral("^[a-z0-9-]{1,32}$"));
    static const QRegularExpression user(QStringLiteral("^user:[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"));
    return bundled.match(value).hasMatch() || user.match(value).hasMatch();
}

QStringList DeviceSettings::availableThemes()
{
    return {QStringLiteral("dreamglass"), QStringLiteral("midnight"), QStringLiteral("aurora"),
            QStringLiteral("ember"), QStringLiteral("daylight")};
}

bool DeviceSettings::isValidTheme(const QString &value)
{
    return availableThemes().contains(value);
}

bool DeviceSettings::isValidMinutes(int value)
{
    return value >= 0 && value <= 24 * 60;
}

void DeviceSettings::setSaverMinutes(int value)
{
    if (!isValidMinutes(value)) {
        qWarning("ruya-shell: rejecting invalid screen saver time %d", value);
        return;
    }
    if (value == m_saverMinutes)
        return;
    m_saverMinutes = value;
    if (m_store)
        m_store->setValue(QStringLiteral("power/saverMinutes"), value);
    emit saverMinutesChanged();
}

void DeviceSettings::setScreenOffMinutes(int value)
{
    if (!isValidMinutes(value)) {
        qWarning("ruya-shell: rejecting invalid screen-off time %d", value);
        return;
    }
    if (value == m_screenOffMinutes)
        return;
    m_screenOffMinutes = value;
    if (m_store)
        m_store->setValue(QStringLiteral("power/screenOffMinutes"), value);
    emit screenOffMinutesChanged();
}

void DeviceSettings::setSleepMinutes(int value)
{
    if (!isValidMinutes(value)) {
        qWarning("ruya-shell: rejecting invalid sleep time %d", value);
        return;
    }
    if (value == m_sleepMinutes)
        return;
    m_sleepMinutes = value;
    if (m_store)
        m_store->setValue(QStringLiteral("power/sleepMinutes"), value);
    emit sleepMinutesChanged();
}

void DeviceSettings::setPadIdleMinutes(int value)
{
    if (!isValidMinutes(value)) {
        qWarning("ruya-shell: rejecting invalid idle-controller time %d", value);
        return;
    }
    if (value == m_padIdleMinutes)
        return;
    m_padIdleMinutes = value;
    if (m_store)
        m_store->setValue(QStringLiteral("power/padIdleMinutes"), value);
    emit padIdleMinutesChanged();
}

bool DeviceSettings::isValidPerformanceInterval(int ms)
{
    return ms >= MinPerformanceIntervalMs && ms <= MaxPerformanceIntervalMs;
}

void DeviceSettings::setPerformanceIntervalMs(int value)
{
    if (!isValidPerformanceInterval(value)) {
        qWarning("ruya-shell: rejecting invalid performance interval %d ms", value);
        return;
    }
    if (value == m_performanceIntervalMs)
        return;
    m_performanceIntervalMs = value;
    if (m_store)
        m_store->setValue(QStringLiteral("hub/performanceIntervalMs"), value);
    emit performanceIntervalMsChanged();
}

void DeviceSettings::setTheme(const QString &value)
{
    if (!isValidTheme(value)) {
        qWarning("ruya-shell: rejecting invalid theme '%s'", qPrintable(value));
        return;
    }
    if (value == m_theme)
        return;
    m_theme = value;
    if (m_store)
        m_store->setValue(QStringLiteral("display/theme"), value);
    emit themeChanged();
}

bool DeviceSettings::reducedMotion() const
{
    return m_forcedMotion.value_or(m_reducedMotion);
}

QString DeviceSettings::effectsQuality() const
{
    if (m_thermalLimited)
        return QStringLiteral("performance");
    return m_forcedQuality.value_or(m_quality);
}

void DeviceSettings::setThermalLimited(bool limited)
{
    if (limited == m_thermalLimited)
        return;
    const QString before = effectsQuality();
    m_thermalLimited = limited;
    emit thermalLimitedChanged();
    if (effectsQuality() != before)
        emit effectsQualityChanged();
}

void DeviceSettings::setReducedMotion(bool value)
{
    if (value == m_reducedMotion)
        return;
    const bool before = reducedMotion();
    m_reducedMotion = value;
    if (m_store)
        m_store->setValue(QStringLiteral("display/reducedMotion"), value);
    if (reducedMotion() != before)
        emit reducedMotionChanged();
}

void DeviceSettings::setEffectsQuality(const QString &value)
{
    if (!isValidQuality(value)) {
        qWarning("ruya-shell: rejecting invalid effectsQuality '%s'", qPrintable(value));
        return;
    }
    if (value == m_quality)
        return;
    const QString before = storedEffectsQuality();
    m_quality = value;
    if (m_store)
        m_store->setValue(QStringLiteral("display/effectsQuality"), value);
    // Also while the console is limited for heat: the effective value stays, the stored one moved.
    if (storedEffectsQuality() != before)
        emit effectsQualityChanged();
}

void DeviceSettings::setOverscan(qreal value)
{
    if (qIsNaN(value) || value < 0.0 || value > kMaxOverscan) {
        qWarning("ruya-shell: rejecting out-of-range overscan %g", value);
        return;
    }
    if (qFuzzyCompare(value + 1.0, m_overscan + 1.0))
        return;
    m_overscan = value;
    if (m_store)
        m_store->setValue(QStringLiteral("display/overscan"), value);
    emit overscanChanged();
}

void DeviceSettings::setWallpaper(const QString &value)
{
    if (!isValidWallpaper(value)) {
        qWarning("ruya-shell: rejecting invalid wallpaper '%s'", qPrintable(value));
        return;
    }
    if (value == m_wallpaper)
        return;
    m_wallpaper = value;
    if (m_store)
        m_store->setValue(QStringLiteral("display/wallpaper"), value);
    emit wallpaperChanged();
}

void DeviceSettings::setSoundTheme(const QString &value)
{
    if (!isValidSoundTheme(value)) {
        qWarning("ruya-shell: rejecting invalid sound theme '%s'", qPrintable(value));
        return;
    }
    if (value == m_soundTheme)
        return;
    m_soundTheme = value;
    if (m_store)
        m_store->setValue(QStringLiteral("sound/theme"), value);
    emit soundThemeChanged();
}

bool DeviceSettings::isValidProfileKey(const QString &id)
{
    static const QRegularExpression valid(QStringLiteral("^[A-Za-z0-9._-]{1,64}$"));
    return valid.match(id).hasMatch();
}

bool DeviceSettings::performanceOverlay(const QString &profile) const
{
    return m_overlayProfiles.value(profile).toBool();
}

void DeviceSettings::setPerformanceOverlay(const QString &profile, bool on)
{
    if (!isValidProfileKey(profile)) {
        qWarning("ruya-shell: rejecting the performance overlay for profile id '%s'", qPrintable(profile));
        return;
    }
    if (on == performanceOverlay(profile))
        return;
    if (on)
        m_overlayProfiles.insert(profile, true);
    else
        m_overlayProfiles.remove(profile);
    if (m_store) {
        const QString key = QStringLiteral("hub/performanceOverlay/") + profile;
        if (on)
            m_store->setValue(key, true);
        else
            m_store->remove(key);
    }
    emit performanceOverlayChanged();
}

void DeviceSettings::setPauseGamesInHub(bool value)
{
    if (value == m_pauseGamesInHub)
        return;
    m_pauseGamesInHub = value;
    if (m_store)
        m_store->setValue(QStringLiteral("hub/pauseGames"), value);
    emit pauseGamesInHubChanged();
}

void DeviceSettings::setAmbientSound(bool value)
{
    if (value == m_ambientSound)
        return;
    m_ambientSound = value;
    if (m_store)
        m_store->setValue(QStringLiteral("sound/ambient"), value);
    emit ambientSoundChanged();
}

void DeviceSettings::setWallpaperDim(qreal value)
{
    if (qIsNaN(value) || value < 0.0 || value > kMaxWallpaperDim) {
        qWarning("ruya-shell: rejecting out-of-range wallpaperDim %g", value);
        return;
    }
    if (qFuzzyCompare(value + 1.0, m_wallpaperDim + 1.0))
        return;
    m_wallpaperDim = value;
    if (m_store)
        m_store->setValue(QStringLiteral("display/wallpaperDim"), value);
    emit wallpaperDimChanged();
}

void DeviceSettings::setLanguage(const QString &value)
{
    if (!isValidLanguage(value)) {
        qWarning("ruya-shell: rejecting invalid language '%s'", qPrintable(value));
        return;
    }
    if (value == m_language)
        return;
    m_language = value;
    if (m_store)
        m_store->setValue(QStringLiteral("general/language"), value);
    applyLanguage(true);
    emit languageChanged();
}
