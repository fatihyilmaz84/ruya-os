#pragma once

#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QSettings>
#include <QString>
#include <QStringList>
#include <QTranslator>

#include <memory>
#include <optional>

// Per-device settings (not per profile): reduced motion, effects quality tier, the
// overscan-safe margin, the colour theme and the UI language (setting it installs the matching QTranslator and
// retranslates the QML engine, so the UI follows live). Persisted with QSettings (ruyaos/shell). With
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
    // Session-only: the console is running hot (T-200), so effectsQuality reads "performance"
    // whatever the owner chose, until this is cleared. Never stored; the owner's choice is kept
    // (storedEffectsQuality) and comes back by itself.
    Q_PROPERTY(bool thermalLimited READ thermalLimited WRITE setThermalLimited NOTIFY thermalLimitedChanged)
    Q_PROPERTY(QString storedEffectsQuality READ storedEffectsQuality NOTIFY effectsQualityChanged)
    // Safe-area margin as a fraction of the screen, 0.0 - 0.10.
    Q_PROPERTY(qreal overscan READ overscan WRITE setOverscan NOTIFY overscanChanged)
    // Colour theme (04 §3.1, T-209): one of availableThemes, default "dreamglass". Stored per device.
    // qml/themes/Themes.qml defines the sets; tst_theme.qml checks that the two lists agree.
    Q_PROPERTY(QString theme READ theme WRITE setTheme NOTIFY themeChanged)
    Q_PROPERTY(QStringList availableThemes READ availableThemes CONSTANT)
    // UI language: "en" | "tr". Chosen in first-boot setup or Settings -> System.
    // Default: the stored value, else the system locale (persistent mode), else "en"; ephemeral = "en".
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
    // The wallpaper (T-208): "" = the default look (the animated blobs), a bundled id ("dusk", ...)
    // or "user:<file>" for a copy in the Wallpapers library. Whether it exists is the library's
    // business; the shell resets it to "" when the picture cannot be loaded.
    Q_PROPERTY(QString wallpaper READ wallpaper WRITE setWallpaper NOTIFY wallpaperChanged)
    // How much the wallpaper is darkened, 0.0 - 0.6 (a picture that needs more for legible text is
    // darkened further, Wallpapers.requiredDim).
    Q_PROPERTY(qreal wallpaperDim READ wallpaperDim WRITE setWallpaperDim NOTIFY wallpaperDimChanged)

public:
    // `persistent == false` keeps everything in memory.
    explicit DeviceSettings(bool persistent, QObject *parent = nullptr);
    // Persistent, in an explicit ini file instead of the system store (tests: a temporary file).
    explicit DeviceSettings(const QString &iniPath, QObject *parent = nullptr);
    ~DeviceSettings() override;

    static DeviceSettings *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    bool reducedMotion() const;
    QString effectsQuality() const;
    QString storedEffectsQuality() const { return m_forcedQuality.value_or(m_quality); }
    bool thermalLimited() const { return m_thermalLimited; }
    qreal overscan() const { return m_overscan; }
    QString language() const { return m_language; }
    QString wallpaper() const { return m_wallpaper; }
    qreal wallpaperDim() const { return m_wallpaperDim; }
    QString theme() const { return m_theme; }
    static QStringList availableThemes();

    // Invalid values are rejected (warning logged) and leave the old value.
    void setReducedMotion(bool value);
    void setEffectsQuality(const QString &value);
    void setThermalLimited(bool limited);
    void setOverscan(qreal value);
    void setLanguage(const QString &value);
    void setWallpaper(const QString &value);
    void setWallpaperDim(qreal value);
    void setTheme(const QString &value);

    // Installs the translator for m_language and, when `retranslate`, refreshes the engine's bindings.
    void applyLanguage(bool retranslate);

    static bool isValidQuality(const QString &value);
    static bool isValidLanguage(const QString &value);
    // "", a lower-case id of letters, digits and dashes, or "user:" and a plain file name.
    Q_INVOKABLE static bool isValidWallpaper(const QString &value);
    static bool isValidTheme(const QString &value);

signals:
    void reducedMotionChanged();
    void effectsQualityChanged();
    void thermalLimitedChanged();
    void overscanChanged();
    void languageChanged();
    void wallpaperChanged();
    void wallpaperDimChanged();
    void themeChanged();

private:
    void init();   // reads the stored values (when there is a store) and the command-line overrides
    std::unique_ptr<QSettings> m_store; // null when ephemeral
    QPointer<QQmlEngine> m_engine;
    QTranslator m_translator;
    bool m_reducedMotion = false;
    QString m_quality = QStringLiteral("high");
    qreal m_overscan = 0.05;
    QString m_language = QStringLiteral("en");
    QString m_wallpaper;
    qreal m_wallpaperDim = 0.2;
    QString m_theme = QStringLiteral("dreamglass");
    std::optional<bool> m_forcedMotion;
    std::optional<QString> m_forcedQuality;
    bool m_thermalLimited = false;
};
