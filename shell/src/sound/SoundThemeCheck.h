#pragma once

#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>

// The sound theme checker (T-227, docs/developers/sound-themes.md): a pure function from a folder to
// "usable or not, and why". The shell calls it for the bundled theme, the copies and the folders on a
// USB drive; `ruya-shell --check-sound-theme <folder>` (scripts/lint-sound-themes.ps1) calls the same
// one. It reads the folder as DATA only: sizes are checked before a file is read, a cue file is read
// whole only when it is at most MaxCueBytes, an Ogg ambient only at its head and tail, a FLAC ambient
// whole (at most MaxAmbientBytes) and decoded by the checker's own small decoder over at most
// MaxMeasuredMs of its loop (no codec library), and nothing is executed. A path that leaves the folder
// (`..`, absolute, a drive letter, a symlink) is refused.
//
// The folder may be a Qt resource (":/..."): the bundled theme of the Windows dev build.
namespace SoundTheme {

constexpr qint64 MaxManifestBytes = 64 * 1024;
constexpr qint64 MaxCueBytes = 200 * 1024;
constexpr qint64 MaxCueMs = 1500;
constexpr qint64 MaxAmbientBytes = 3 * 1024 * 1024;
constexpr qint64 MinLoopMs = 5000;         // a loop shorter than this repeats too obviously
constexpr int CueSampleRate = 48000;
constexpr int MaxCues = 64;                // entries in the manifest's "cues"
constexpr double PeakLimit = 0.70794578;   // -3 dBFS
// The ambient must be heard on a TV and a 5 cm speaker (T-330), measured on the decoded loop of a FLAC
// ambient (an Ogg one is not decoded: a warning says it was not measured).
constexpr double LowCutHz = 150.0;
constexpr double MaxLowShare = 0.5;        // refused when more than half the energy is below 150 Hz
constexpr double MinAmbientDbfs = -40.0;   // refused when the median 1 s RMS of the loop is below this
constexpr qint64 MaxMeasuredMs = 60000;    // the first minute of the loop is measured, the rest is not decoded

// The cue names: the contract between the shell and a theme (Sfx.qml has one function for each).
const QStringList &cueNames();

struct Ambient
{
    QString file;              // absolute path (or ":/..." for a resource)
    qint64 loopStartMs = 0;
    qint64 loopEndMs = 0;
    double gain = 1.0;         // 0..1, before the Ambient slider
    qint64 durationMs = 0;
    bool measured = false;     // a FLAC ambient: the two numbers below are known
    double levelDbfs = 0;      // the median 1 s RMS of the measured loop, before the gain
    double lowShare = 0;       // the share of its energy below LowCutHz, 0..1
};

struct Manifest
{
    QString name;
    QString author;
    QString licence;
    QString version;
    QMap<QString, QString> cues;   // cue name -> absolute file path; only known cue names
    QMap<QString, qint64> cueMs;   // cue name -> length in ms
    bool hasAmbient = false;
    Ambient ambient;
};

struct Result
{
    bool ok = false;
    QStringList problems;          // why the theme is refused (empty when ok)
    QStringList warnings;          // things worth fixing that do not stop the theme
    Manifest manifest;             // filled when ok
};

// Checks the theme in `dir` (theme.json and the files it names).
Result check(const QString &dir);

// A fixture folder for tests and for the lint: `root` gets one sub-folder for each case below.
struct FixtureCase
{
    QString name;             // the sub-folder; "ok-..." must pass, "bad-..." must fail
    bool shouldPass;
    QString expect;           // text that must appear in a problem of a "bad-" case
};
QList<FixtureCase> fixtureCases();
bool writeFixtures(const QString &root);

// Hostile-file test: valid WAV, Ogg and FLAC files with their first 128 bytes cut, corrupted and their 4-byte
// fields set to 0, 1, 0x7fffffff, 0x80000000 and 0xfffffff8, each checked in a worker thread. True when every
// file got a verdict within `timeoutMs` in total; otherwise `problem` says why (a hung checker is abandoned).
// `cases` is the number of files tried.
bool fuzz(QString *problem, int *cases, int timeoutMs = 60000);

} // namespace SoundTheme
