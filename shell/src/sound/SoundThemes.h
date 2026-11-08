#pragma once

#include "SoundThemeCheck.h"

#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QStringList>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// Sound themes (T-227, docs/developers/sound-themes.md): which files the UI cues and the ambient loop
// play. A theme is a folder with a theme.json; `SoundThemeCheck` decides whether one is usable.
//
//   bundled   "dreamglass": /usr/share/ruyaos/sounds/dreamglass on the image, a Qt resource in the
//             Windows dev build. Always checked at start-up; a cue a theme does not name comes from here.
//   installed "user:<folder>": a copy in the shell's own data directory (<AppData>/sounds/<folder>), made
//             by importTheme from a USB drive, so it keeps working when the stick is gone.
//   drive     a folder RuyaOS/sounds/<folder>/ on a mounted removable volume; listed after refresh().
//
// The chosen id is DeviceSettings.soundTheme, handed in through `selectedId` (Sfx.qml binds it). A
// chosen theme that fails the checker is ignored with a log line and the bundled one plays
// (`selectedBroken`). Nothing on a drive is executed or loaded in place: it is checked as data, in a
// worker thread, and copied before use.
class SoundThemes : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString bundledId READ bundledId CONSTANT)
    Q_PROPERTY(QString selectedId READ selectedId WRITE setSelectedId NOTIFY selectedIdChanged)
    // The theme that plays: selectedId when it is usable, else the bundled one.
    Q_PROPERTY(QString activeId READ activeId NOTIFY activeChanged)
    Q_PROPERTY(bool selectedBroken READ selectedBroken NOTIFY activeChanged)
    // cue name -> URL, for every cue that has a file: the active theme's, else the bundled theme's.
    Q_PROPERTY(QVariantMap cues READ cues NOTIFY activeChanged)
    // The active theme's ambient loop (a theme without one has no ambient sound).
    Q_PROPERTY(QString ambientUrl READ ambientUrl NOTIFY activeChanged)
    Q_PROPERTY(int ambientLoopStart READ ambientLoopStart NOTIFY activeChanged)
    Q_PROPERTY(int ambientLoopEnd READ ambientLoopEnd NOTIFY activeChanged)
    Q_PROPERTY(qreal ambientGain READ ambientGain NOTIFY activeChanged)
    // [{ id, name, author, licence, kind: "bundled"|"installed"|"drive", path }]: bundled first, then the
    // copies, then the themes found on drives by the last refresh().
    Q_PROPERTY(QVariantList themes READ themes NOTIFY themesChanged)
    // [{ id, folder, problem, problems }]: folders on a drive that the checker refused in the last refresh();
    // `problems` is the checker's list, `problem` the same joined (SoundThemeText.qml puts it into plain words).
    Q_PROPERTY(QVariantList driveProblems READ driveProblems NOTIFY themesChanged)
    // "idle" | "copying" while importTheme works; the answer is importFinished.
    Q_PROPERTY(QString importState READ importState NOTIFY importStateChanged)
    // Ambient timing (02 §5): the fade in and out, and how far a cue lowers the ambient bed.
    Q_PROPERTY(int ambientFadeMs READ ambientFadeMs CONSTANT)
    Q_PROPERTY(int duckMs READ duckMs CONSTANT)               // the shortest hold of the duck after a cue
    Q_PROPERTY(int duckRampMs READ duckRampMs CONSTANT)       // the bed's level follows the duck over this
    Q_PROPERTY(int crossMs READ crossMs CONSTANT)             // the ambient loop's cross-fade at its end
    Q_PROPERTY(int loopPollMs READ loopPollMs CONSTANT)       // how often the loop's position is looked at
    // cue name -> length in ms (from the checker), for the cues in `cues`: the duck is held that long.
    Q_PROPERTY(QVariantMap cueMs READ cueLengths NOTIFY activeChanged)
    Q_PROPERTY(qreal duckGain READ duckGain CONSTANT)
    Q_PROPERTY(int installedLimit READ installedLimit CONSTANT)
    Q_PROPERTY(int maxCopyFiles READ maxCopyFiles CONSTANT)      // a theme may have at most this many files ...
    Q_PROPERTY(int maxCopyMb READ maxCopyMb CONSTANT)            // ... and this many MiB to be copied
    // RUYA_SOUNDS_DRY=1 (tests): the ambient players are given no file, so a test run makes no noise.
    Q_PROPERTY(bool dry READ isDry CONSTANT)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    static constexpr int AmbientFadeMs = 800;
    static constexpr int DuckMs = 450;              // the shortest time the bed stays lowered after a cue starts
    static constexpr int DuckRampMs = 120;
    static constexpr int CrossMs = 1500;
    static constexpr int LoopPollMs = 50;
    static constexpr double DuckDb = -8.0;
    static constexpr int InstalledLimit = 8;
    static constexpr int MaxDriveFolders = 16;      // folders looked at per drive
    static constexpr int MaxCopyFiles = 100;        // a theme is at most 64 cues, one ambient file and a few texts
    static constexpr int MaxCopyMb = 12;
    static constexpr qint64 MaxCopyBytes = qint64(MaxCopyMb) * 1024 * 1024;

    explicit SoundThemes(QObject *parent = nullptr);
    ~SoundThemes() override;

    static SoundThemes *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QString bundledId() const { return QStringLiteral("dreamglass"); }
    QString selectedId() const { return m_selectedId; }
    void setSelectedId(const QString &id);
    QString activeId() const { return m_activeId; }
    bool selectedBroken() const { return m_broken; }
    QVariantMap cues() const { return m_cues; }
    QString ambientUrl() const { return m_ambientUrl; }
    int ambientLoopStart() const { return m_loopStart; }
    int ambientLoopEnd() const { return m_loopEnd; }
    qreal ambientGain() const { return m_ambientGain; }
    QVariantList themes() const { return m_themes; }
    QVariantList driveProblems() const { return m_driveProblems; }
    QString importState() const { return m_importing ? QStringLiteral("copying") : QStringLiteral("idle"); }
    int ambientFadeMs() const { return AmbientFadeMs; }
    int duckMs() const { return DuckMs; }
    int duckRampMs() const { return DuckRampMs; }
    int crossMs() const { return CrossMs; }
    int loopPollMs() const { return LoopPollMs; }
    QVariantMap cueLengths() const { return m_cueMs; }
    qreal duckGain() const;
    int installedLimit() const { return InstalledLimit; }
    int maxCopyFiles() const { return MaxCopyFiles; }
    int maxCopyMb() const { return MaxCopyMb; }
    bool isMock() const { return m_mock; }
    bool isDry() const { return qEnvironmentVariableIntValue("RUYA_SOUNDS_DRY") != 0; }

    // Looks at the copies and at RuyaOS/sounds/ on these mount points (a mounted removable volume
    // each), off the GUI thread; themesChanged follows. A newer call drops an older one's answer.
    Q_INVOKABLE void refresh(const QStringList &mountPoints);
    // Copies a theme listed with kind "drive" (its `path`) into the data directory; any other path is
    // refused. importState is "copying" at once; importFinished(status, id, problems) follows: "ok" (id is
    // the new "user:<folder>"), "invalid" (the checker refused it, also after copying; `problems` is its
    // list), "limit" (already InstalledLimit copies), "too-many-files" (more than MaxCopyFiles files),
    // "too-large" (more than MaxCopyMb MiB), "unknown" (not a listed drive theme) or "io".
    Q_INVOKABLE void importTheme(const QString &path);
    // Deletes the copy "user:<folder>" from the data directory. False when `id` is not a copy that exists
    // (the bundled theme and the themes on drives cannot be deleted). If it is the chosen theme, the bundled
    // one is chosen instead; the caller also resets the setting (DeviceSettings.soundTheme) first.
    Q_INVOKABLE bool removeTheme(const QString &id);

    // The checker for QML: { ok, problems, warnings, name, cues (count), hasAmbient }.
    Q_INVOKABLE static QVariantMap check(const QString &folder);
    // Tests and the lint: fixture folders (SoundTheme::fixtureCases) written under a temporary
    // directory that lives as long as this object; the path, or "" on failure.
    Q_INVOKABLE QString fixturesDir();
    Q_INVOKABLE static QVariantList fixtureCases();
    // The hostile-file test of SoundTheme::fuzz: { ok, cases, problem }. Takes a few seconds; bounded by `timeoutMs`.
    Q_INVOKABLE static QVariantMap fuzz(int timeoutMs = 60000);

    // Tests only, with the mock backend (otherwise no-ops). mockPrepareDrive writes a stick tree
    // (RuyaOS/sounds/Glassy: usable, Plain: usable, Broken: refused) and makes the mock stick's mount
    // point ("/run/media/mock/<label>") read from it; it returns the path. mockDriveCopyDelay makes each
    // import take this long (ms) on its worker. mockReset deletes the copies.
    Q_INVOKABLE QString mockPrepareDrive();
    Q_INVOKABLE void mockSetCopyDelay(int ms);
    // Adds a usable theme folder to the mock stick (after mockPrepareDrive) with exactly `files` files and
    // `bytes` bytes in all, to try the copy limits; false when it cannot be made that way.
    Q_INVOKABLE bool mockAddDriveTheme(const QString &folder, int files, qint64 bytes);
    Q_INVOKABLE void mockReset();

signals:
    void selectedIdChanged();
    void activeChanged();
    void themesChanged();
    void importStateChanged();
    void importFinished(const QString &status, const QString &id, const QStringList &problems);

private:
    struct Scan;
    void loadBundled();
    void reload();
    void rebuildThemes();
    QString mapMount(const QString &mountPoint) const;
    static QString urlOf(const QString &path);
    static QVariantMap entry(const QString &id, const SoundTheme::Manifest &m, const QString &kind, const QString &path);

    QString m_dir;                                 // the copies
    std::unique_ptr<QTemporaryDir> m_tempDir;      // the copies' directory while settings are ephemeral (tests)
    bool m_mock = false;
    QString m_bundledDir;
    SoundTheme::Result m_bundled;
    QString m_selectedId;
    QString m_activeId;
    bool m_broken = false;
    SoundTheme::Manifest m_active;
    QVariantMap m_cues;
    QVariantMap m_cueMs;
    QString m_ambientUrl;
    int m_loopStart = 0;
    int m_loopEnd = 0;
    qreal m_ambientGain = 1.0;
    QVariantList m_themes;
    QVariantList m_installed;                      // entries of the copies (from the last refresh, else only the selected)
    QVariantList m_drive;                          // entries found on drives
    QVariantList m_driveProblems;
    bool m_importing = false;
    quint64 m_scanSerial = 0;
    int m_copyDelayMs = 0;
    std::unique_ptr<QTemporaryDir> m_mockDrive;
    std::unique_ptr<QTemporaryDir> m_fixtures;
};
