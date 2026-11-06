#include "DeviceSettings.h"

#include <QCoreApplication>
#include <QLocale>
#include <QMetaObject>
#include <QtMath>

namespace {
constexpr qreal kMaxOverscan = 0.10;
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
        const QString theme = m_store->value(QStringLiteral("display/theme"), m_theme).toString();
        if (isValidTheme(theme))
            m_theme = theme;
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

QStringList DeviceSettings::availableThemes()
{
    return {QStringLiteral("dreamglass"), QStringLiteral("midnight"), QStringLiteral("aurora"),
            QStringLiteral("ember"), QStringLiteral("daylight")};
}

bool DeviceSettings::isValidTheme(const QString &value)
{
    return availableThemes().contains(value);
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
