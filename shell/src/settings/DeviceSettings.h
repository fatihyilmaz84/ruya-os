#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QString>

#include <memory>
#include <optional>

// Per-device settings (not per profile): reduced motion, effects quality tier, the
// overscan-safe margin and the UI language. Persisted with QSettings (ruyaos/shell). With
// RUYA_SETTINGS_EPHEMERAL=1 values live in memory only (tests).
//
// Command-line overrides (--reduced-motion, --effects) are session-only: main.cpp passes
// them as RUYA_FORCE_REDUCED_MOTION / RUYA_FORCE_EFFECTS; they win over the stored value
// and are never written back.
class DeviceSettings : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool reducedMotion READ reducedMotion WRITE setReducedMotion NOTIFY reducedMotionChanged)
    // "high" | "balanced" | "performance"
    Q_PROPERTY(QString effectsQuality READ effectsQuality WRITE setEffectsQuality NOTIFY effectsQualityChanged)
    // Safe-area margin as a fraction of the screen, 0.0 - 0.10.
    Q_PROPERTY(qreal overscan READ overscan WRITE setOverscan NOTIFY overscanChanged)
    // UI language: "en" | "tr". Chosen in first-boot setup; T-109 makes the UI follow it.
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)

public:
    // `persistent == false` keeps everything in memory.
    explicit DeviceSettings(bool persistent, QObject *parent = nullptr);
    ~DeviceSettings() override;

    static DeviceSettings *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    bool reducedMotion() const;
    QString effectsQuality() const;
    qreal overscan() const { return m_overscan; }
    QString language() const { return m_language; }

    // Invalid values are rejected (warning logged) and leave the old value.
    void setReducedMotion(bool value);
    void setEffectsQuality(const QString &value);
    void setOverscan(qreal value);
    void setLanguage(const QString &value);

    static bool isValidQuality(const QString &value);
    static bool isValidLanguage(const QString &value);

signals:
    void reducedMotionChanged();
    void effectsQualityChanged();
    void overscanChanged();
    void languageChanged();

private:
    std::unique_ptr<QSettings> m_store; // null when ephemeral
    bool m_reducedMotion = false;
    QString m_quality = QStringLiteral("high");
    qreal m_overscan = 0.05;
    QString m_language = QStringLiteral("en");
    std::optional<bool> m_forcedMotion;
    std::optional<QString> m_forcedQuality;
};
