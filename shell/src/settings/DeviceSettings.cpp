#include "DeviceSettings.h"

#include <QtMath>

namespace {
constexpr qreal kMaxOverscan = 0.10;
}

DeviceSettings::DeviceSettings(bool persistent, QObject *parent)
    : QObject(parent)
{
    if (persistent) {
        m_store = std::make_unique<QSettings>(QStringLiteral("ruyaos"), QStringLiteral("shell"));
        m_reducedMotion = m_store->value(QStringLiteral("display/reducedMotion"), false).toBool();
        const QString quality = m_store->value(QStringLiteral("display/effectsQuality"), m_quality).toString();
        if (isValidQuality(quality))
            m_quality = quality;
        bool ok = false;
        const qreal overscan = m_store->value(QStringLiteral("display/overscan"), m_overscan).toReal(&ok);
        if (ok && overscan >= 0.0 && overscan <= kMaxOverscan)
            m_overscan = overscan;
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

DeviceSettings::~DeviceSettings() = default;

DeviceSettings *DeviceSettings::create(QQmlEngine *, QJSEngine *)
{
    return new DeviceSettings(qEnvironmentVariableIntValue("RUYA_SETTINGS_EPHEMERAL") == 0);
}

bool DeviceSettings::isValidQuality(const QString &value)
{
    return value == QLatin1String("high") || value == QLatin1String("balanced")
        || value == QLatin1String("performance");
}

bool DeviceSettings::reducedMotion() const
{
    return m_forcedMotion.value_or(m_reducedMotion);
}

QString DeviceSettings::effectsQuality() const
{
    return m_forcedQuality.value_or(m_quality);
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
    const QString before = effectsQuality();
    m_quality = value;
    if (m_store)
        m_store->setValue(QStringLiteral("display/effectsQuality"), value);
    if (effectsQuality() != before)
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
