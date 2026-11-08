#include "SoundThemes.h"

#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QPointer>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QThread>
#include <QThreadPool>
#include <QUrl>
#include <QtMath>

namespace {

const QString UserPrefix = QStringLiteral("user:");

enum class CopyFail { None, Io, TooManyFiles, TooLarge };

bool useMock()
{
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    return choice == QLatin1String("mock");
#else
    return choice != QLatin1String("dbus");
#endif
}

bool isFolderName(const QString &name)
{
    static const QRegularExpression re(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"));
    return re.match(name).hasMatch();
}

// The bundled theme: RUYA_SOUNDS_DIR (a folder of themes) if set, /usr/share/ruyaos/sounds on Linux, else the
// Qt resource (the Windows dev build, and the fallback if the image folder is missing).
QString bundledDirectory(const QString &id)
{
    const QString fixed = qEnvironmentVariable("RUYA_SOUNDS_DIR");
    if (!fixed.isEmpty())
        return fixed + QLatin1Char('/') + id;
#ifdef Q_OS_LINUX
    const QString system = QStringLiteral("/usr/share/ruyaos/sounds/") + id;
    if (QFileInfo(system + QStringLiteral("/theme.json")).isFile())
        return system;
#endif
    return QStringLiteral(":/qt/qml/RuyaShell/sounds/") + id;
}

// Copies the regular files of `from` to `to` (no links), at most MaxCopyFiles files and MaxCopyBytes (exactly
// that many is fine); `why` says which limit stopped it.
bool copyTree(const QString &from, const QString &to, CopyFail *why = nullptr)
{
    CopyFail ignored = CopyFail::None;
    CopyFail &fail = why ? *why : ignored;
    fail = CopyFail::None;
    if (!QDir().mkpath(to)) {
        fail = CopyFail::Io;
        return false;
    }
    int files = 0;
    qint64 bytes = 0;
    QDirIterator it(from, QDir::Files | QDir::NoSymLinks | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
    const QDir base(from);
    while (it.hasNext()) {
        const QString path = it.next();
        const QFileInfo info(path);
        bytes += info.size();
        if (++files > SoundThemes::MaxCopyFiles) {
            fail = CopyFail::TooManyFiles;
            return false;
        }
        if (bytes > SoundThemes::MaxCopyBytes) {
            fail = CopyFail::TooLarge;
            return false;
        }
        const QString target = to + QLatin1Char('/') + base.relativeFilePath(path);
        if (!QDir().mkpath(QFileInfo(target).path()) || !QFile::copy(path, target)) {
            fail = CopyFail::Io;
            return false;
        }
    }
    return true;
}

// Gives the theme in `folder` the name `name` in its theme.json.
bool renameTheme(const QString &folder, const QString &name)
{
    QFile manifest(folder + QStringLiteral("/theme.json"));
    if (!manifest.open(QIODevice::ReadWrite))
        return false;
    QJsonObject o = QJsonDocument::fromJson(manifest.readAll()).object();
    o.insert(QStringLiteral("name"), name);
    manifest.resize(0);
    manifest.write(QJsonDocument(o).toJson());
    return true;
}

} // namespace

SoundThemes::SoundThemes(QObject *parent)
    : QObject(parent)
    , m_mock(useMock())
{
    const QString fixed = qEnvironmentVariable("RUYA_SOUND_DIR");
    if (!fixed.isEmpty()) {
        m_dir = fixed;
    } else if (qEnvironmentVariableIntValue("RUYA_SETTINGS_EPHEMERAL") != 0) {
        m_tempDir = std::make_unique<QTemporaryDir>();      // tests: a directory of their own
        m_dir = m_tempDir->path();
    } else {
        m_dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + QStringLiteral("/sounds");
    }
    QDir().mkpath(m_dir);
    loadBundled();
    m_selectedId = bundledId();
    reload();
}

SoundThemes::~SoundThemes() = default;

SoundThemes *SoundThemes::create(QQmlEngine *, QJSEngine *)
{
    return new SoundThemes;
}

qreal SoundThemes::duckGain() const
{
    return qPow(10.0, DuckDb / 20.0);
}

QString SoundThemes::urlOf(const QString &path)
{
    if (path.startsWith(QLatin1Char(':')))
        return QStringLiteral("qrc") + path;
    return QUrl::fromLocalFile(path).toString();
}

QVariantMap SoundThemes::entry(const QString &id, const SoundTheme::Manifest &m, const QString &kind, const QString &path)
{
    return {{QStringLiteral("id"), id}, {QStringLiteral("name"), m.name}, {QStringLiteral("author"), m.author},
            {QStringLiteral("licence"), m.licence}, {QStringLiteral("version"), m.version}, {QStringLiteral("kind"), kind},
            {QStringLiteral("path"), path}};
}

void SoundThemes::loadBundled()
{
    m_bundledDir = bundledDirectory(bundledId());
    m_bundled = SoundTheme::check(m_bundledDir);
    if (!m_bundled.ok)
        qWarning("ruya-shell: the bundled sound theme is unusable (%s): %s", qPrintable(m_bundledDir), qPrintable(m_bundled.problems.join(QStringLiteral("; "))));
}

void SoundThemes::setSelectedId(const QString &id)
{
    const QString wanted = id.isEmpty() ? bundledId() : id;
    if (wanted == m_selectedId)
        return;
    m_selectedId = wanted;
    reload();
    emit selectedIdChanged();
}

// Works out which theme plays: the chosen one if the checker accepts it, else the bundled one.
void SoundThemes::reload()
{
    SoundTheme::Manifest active = m_bundled.manifest;
    QString activeId = bundledId();
    m_broken = false;
    if (m_selectedId != bundledId()) {
        bool usable = false;
        if (m_selectedId.startsWith(UserPrefix) && isFolderName(m_selectedId.mid(UserPrefix.size()))) {
            const QString folder = m_dir + QLatin1Char('/') + m_selectedId.mid(UserPrefix.size());
            const SoundTheme::Result r = SoundTheme::check(folder);
            if (r.ok) {
                active = r.manifest;
                activeId = m_selectedId;
                usable = true;
                bool known = false;
                for (const QVariant &e : std::as_const(m_installed))
                    known = known || e.toMap().value(QStringLiteral("id")).toString() == m_selectedId;
                if (!known)
                    m_installed.append(entry(m_selectedId, r.manifest, QStringLiteral("installed"), folder));
            } else {
                qWarning("ruya-shell: sound theme '%s' ignored, the bundled one plays: %s", qPrintable(m_selectedId),
                         qPrintable(r.problems.join(QStringLiteral("; "))));
            }
        } else {
            qWarning("ruya-shell: sound theme '%s' ignored: not a theme id", qPrintable(m_selectedId));
        }
        m_broken = !usable;
    }
    m_active = active;
    m_activeId = activeId;

    // A cue the active theme does not name comes from the bundled one; the ambient has no fallback.
    QVariantMap cues;
    QVariantMap lengths;
    for (const SoundTheme::Manifest *m : {&m_bundled.manifest, &active}) {       // the active theme's entries win
        for (auto it = m->cues.cbegin(); it != m->cues.cend(); ++it) {
            cues.insert(it.key(), urlOf(it.value()));
            lengths.insert(it.key(), m->cueMs.value(it.key()));
        }
    }
    m_cues = cues;
    m_cueMs = lengths;
    if (active.hasAmbient) {
        m_ambientUrl = urlOf(active.ambient.file);
        m_loopStart = int(active.ambient.loopStartMs);
        m_loopEnd = int(active.ambient.loopEndMs);
        m_ambientGain = active.ambient.gain;
    } else {
        m_ambientUrl.clear();
        m_loopStart = m_loopEnd = 0;
        m_ambientGain = 1.0;
    }
    rebuildThemes();
    emit activeChanged();
}

void SoundThemes::rebuildThemes()
{
    QVariantList list;
    list.append(entry(bundledId(), m_bundled.manifest, QStringLiteral("bundled"), m_bundledDir));
    QStringList installedFolders;
    for (const QVariant &e : std::as_const(m_installed)) {
        list.append(e);
        installedFolders.append(e.toMap().value(QStringLiteral("id")).toString().mid(UserPrefix.size()) + QLatin1Char('|')
                                + e.toMap().value(QStringLiteral("version")).toString());
    }
    for (const QVariant &e : std::as_const(m_drive)) {
        const QVariantMap m = e.toMap();
        // The same folder name and version already copied: nothing new to offer.
        if (installedFolders.contains(m.value(QStringLiteral("folder")).toString() + QLatin1Char('|') + m.value(QStringLiteral("version")).toString()))
            continue;
        list.append(e);
    }
    m_themes = list;
    emit themesChanged();
}

QString SoundThemes::mapMount(const QString &mountPoint) const
{
    // The mock stick has no real mount: its path is read from the mock tree, when there is one.
    const QString mockBase = QStringLiteral("/run/media/mock/");
    if (m_mock && m_mockDrive && mountPoint.startsWith(mockBase))
        return m_mockDrive->path() + QLatin1Char('/') + mountPoint.mid(mockBase.size());
    return mountPoint;
}

void SoundThemes::refresh(const QStringList &mountPoints)
{
    const quint64 serial = ++m_scanSerial;
    QStringList roots;
    QStringList volumes;
    for (const QString &mount : mountPoints) {
        if (mount.isEmpty())
            continue;
        roots.append(mapMount(mount));
        volumes.append(QFileInfo(mount).fileName());
    }
    const QString dir = m_dir;
    QPointer<SoundThemes> self(this);
    QThreadPool::globalInstance()->start([self, serial, roots, volumes, dir] {
        QVariantList installed;
        QVariantList drive;
        QVariantList problems;
        // The copies.
        const QStringList copies = QDir(dir).entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks, QDir::Name | QDir::IgnoreCase);
        for (const QString &folder : copies) {
            if (!isFolderName(folder))
                continue;
            const SoundTheme::Result r = SoundTheme::check(dir + QLatin1Char('/') + folder);
            if (!r.ok) {
                qWarning("ruya-shell: sound theme copy '%s' ignored: %s", qPrintable(folder), qPrintable(r.problems.join(QStringLiteral("; "))));
                continue;
            }
            installed.append(entry(UserPrefix + folder, r.manifest, QStringLiteral("installed"), dir + QLatin1Char('/') + folder));
        }
        // The drives: <mount>/RuyaOS/sounds/<folder>/
        for (int i = 0; i < roots.size(); ++i) {
            const QDir root(roots.at(i));
            const QStringList top = root.entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks);
            for (const QString &ruya : top) {
                if (ruya.compare(QLatin1String("RuyaOS"), Qt::CaseInsensitive) != 0)
                    continue;
                const QDir ruyaDir(root.filePath(ruya));
                for (const QString &sounds : ruyaDir.entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks)) {
                    if (sounds.compare(QLatin1String("sounds"), Qt::CaseInsensitive) != 0)
                        continue;
                    const QDir soundsDir(ruyaDir.filePath(sounds));
                    const QStringList folders = soundsDir.entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks, QDir::Name | QDir::IgnoreCase);
                    int looked = 0;
                    for (const QString &folder : folders) {
                        if (++looked > MaxDriveFolders)
                            break;
                        const QString path = soundsDir.filePath(folder);
                        QStringList why;
                        SoundTheme::Result r;
                        const QString id = QStringLiteral("drive:") + volumes.at(i) + QLatin1Char('/') + folder;
                        if (!isFolderName(folder)) {
                            why.append(QStringLiteral("the folder name is not usable (letters, digits, . _ -)"));
                        } else {
                            r = SoundTheme::check(path);
                            if (!r.ok)
                                why = r.problems;
                        }
                        if (!why.isEmpty()) {
                            const QString problem = why.join(QStringLiteral("; "));
                            qWarning("ruya-shell: sound theme '%s' on the drive ignored: %s", qPrintable(folder), qPrintable(problem));
                            problems.append(QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("folder"), folder},
                                                        {QStringLiteral("problem"), problem}, {QStringLiteral("problems"), why}});
                            continue;
                        }
                        QVariantMap e = entry(id, r.manifest, QStringLiteral("drive"), path);
                        e.insert(QStringLiteral("folder"), folder);
                        drive.append(e);
                    }
                }
            }
        }
        QMetaObject::invokeMethod(qApp, [self, serial, installed, drive, problems] {
            if (!self || serial != self->m_scanSerial)
                return;                              // a newer refresh was asked for meanwhile
            // A copy deleted while the scan ran is not listed again.
            QVariantList present;
            for (const QVariant &e : std::as_const(installed)) {
                if (QFileInfo(e.toMap().value(QStringLiteral("path")).toString()).isDir())
                    present.append(e);
            }
            self->m_installed = present;
            // The chosen copy stays listed even if it has just been found unusable on disk.
            self->m_drive = drive;
            self->m_driveProblems = problems;
            self->rebuildThemes();
        }, Qt::QueuedConnection);
    });
}

void SoundThemes::importTheme(const QString &path)
{
    if (m_importing)
        return;
    bool listed = false;
    for (const QVariant &e : std::as_const(m_drive))
        listed = listed || e.toMap().value(QStringLiteral("path")).toString() == path;
    if (!listed) {
        QMetaObject::invokeMethod(this, [this] { emit importFinished(QStringLiteral("unknown"), QString(), QStringList()); }, Qt::QueuedConnection);
        return;
    }
    m_importing = true;
    emit importStateChanged();
    const QString dir = m_dir;
    const QString folder = QFileInfo(path).fileName();
    const int delay = m_copyDelayMs;
    QPointer<SoundThemes> self(this);
    QThreadPool::globalInstance()->start([self, path, dir, folder, delay] {
        QString status = QStringLiteral("ok");
        QStringList refused;
        SoundTheme::Result done;
        const QString dest = dir + QLatin1Char('/') + folder;
        const QString incoming = dir + QStringLiteral("/.incoming");
        if (delay > 0)
            QThread::msleep(ulong(delay));
        int existing = 0;
        for (const QString &name : QDir(dir).entryList(QDir::Dirs | QDir::NoDotAndDotDot))
            existing += isFolderName(name) ? 1 : 0;
        const SoundTheme::Result source = SoundTheme::check(path);
        if (!source.ok) {
            status = QStringLiteral("invalid");
            refused = source.problems;
        } else if (existing >= InstalledLimit && !QFileInfo(dest).isDir()) {
            status = QStringLiteral("limit");
        } else {
            QDir(incoming).removeRecursively();
            CopyFail fail = CopyFail::None;
            if (!copyTree(path, incoming, &fail)) {
                status = fail == CopyFail::TooManyFiles ? QStringLiteral("too-many-files")
                       : fail == CopyFail::TooLarge ? QStringLiteral("too-large") : QStringLiteral("io");
            } else {
                done = SoundTheme::check(incoming);       // what was copied must pass, too
                if (!done.ok) {
                    status = QStringLiteral("invalid");
                    refused = done.problems;
                } else {
                    QDir(dest).removeRecursively();
                    if (!QDir().rename(incoming, dest))
                        status = QStringLiteral("io");
                    else
                        done = SoundTheme::check(dest);
                }
            }
            QDir(incoming).removeRecursively();
        }
        QMetaObject::invokeMethod(qApp, [self, status, folder, dest, done, refused] {
            if (!self)
                return;
            self->m_importing = false;
            emit self->importStateChanged();
            const QString id = UserPrefix + folder;
            if (status == QLatin1String("ok")) {
                QVariantList installed;
                for (const QVariant &e : std::as_const(self->m_installed)) {
                    if (e.toMap().value(QStringLiteral("id")).toString() != id)
                        installed.append(e);
                }
                installed.append(entry(id, done.manifest, QStringLiteral("installed"), dest));
                self->m_installed = installed;
                if (self->m_selectedId == id)
                    self->reload();           // the copy replaced the one that plays
                else
                    self->rebuildThemes();
            }
            emit self->importFinished(status, status == QLatin1String("ok") ? id : QString(), refused);
        }, Qt::QueuedConnection);
    });
}

bool SoundThemes::removeTheme(const QString &id)
{
    if (!id.startsWith(UserPrefix) || !isFolderName(id.mid(UserPrefix.size())) || m_importing)
        return false;
    const QString path = m_dir + QLatin1Char('/') + id.mid(UserPrefix.size());
    const QFileInfo info(path);
    if (!info.exists())
        return false;
    if (m_selectedId == id)
        setSelectedId(bundledId());                         // the bundled theme plays (no cue, no toast) and lets go of the files
    if (info.isSymLink())
        QFile::remove(path);                                // only the link, never what it points to
    else
        QDir(path).removeRecursively();
    const bool gone = !QFileInfo::exists(path);
    if (gone)
        m_installed.removeIf([&id](const QVariant &e) { return e.toMap().value(QStringLiteral("id")).toString() == id; });
    rebuildThemes();
    return gone;
}

QVariantMap SoundThemes::check(const QString &folder)
{
    const SoundTheme::Result r = SoundTheme::check(folder);
    return {{QStringLiteral("ok"), r.ok}, {QStringLiteral("problems"), r.problems}, {QStringLiteral("warnings"), r.warnings},
            {QStringLiteral("name"), r.manifest.name}, {QStringLiteral("cues"), r.manifest.cues.size()},
            {QStringLiteral("hasAmbient"), r.manifest.hasAmbient}, {QStringLiteral("loopStart"), r.manifest.ambient.loopStartMs},
            {QStringLiteral("loopEnd"), r.manifest.ambient.loopEndMs}, {QStringLiteral("ambientMeasured"), r.manifest.ambient.measured},
            {QStringLiteral("ambientLevel"), r.manifest.ambient.levelDbfs}, {QStringLiteral("ambientLowShare"), r.manifest.ambient.lowShare}};
}

QString SoundThemes::fixturesDir()
{
    if (!m_fixtures) {
        m_fixtures = std::make_unique<QTemporaryDir>();
        if (!m_fixtures->isValid() || !SoundTheme::writeFixtures(m_fixtures->path()))
            return QString();
    }
    return m_fixtures->path();
}

QVariantList SoundThemes::fixtureCases()
{
    QVariantList list;
    for (const SoundTheme::FixtureCase &c : SoundTheme::fixtureCases())
        list.append(QVariantMap{{QStringLiteral("name"), c.name}, {QStringLiteral("shouldPass"), c.shouldPass}, {QStringLiteral("expect"), c.expect}});
    return list;
}

QVariantMap SoundThemes::fuzz(int timeoutMs)
{
    QString problem;
    int cases = 0;
    const bool ok = SoundTheme::fuzz(&problem, &cases, timeoutMs);
    return {{QStringLiteral("ok"), ok}, {QStringLiteral("cases"), cases}, {QStringLiteral("problem"), problem}};
}

QString SoundThemes::mockPrepareDrive()
{
    if (!m_mock)
        return QString();
    const QString fixtures = fixturesDir();
    if (fixtures.isEmpty())
        return QString();
    m_mockDrive = std::make_unique<QTemporaryDir>();
    const QString sounds = m_mockDrive->path() + QStringLiteral("/Ruya Stick/RuyaOS/sounds");
    bool ok = QDir().mkpath(sounds);
    ok = copyTree(fixtures + QStringLiteral("/ok-full"), sounds + QStringLiteral("/Glassy")) && ok;
    ok = copyTree(fixtures + QStringLiteral("/ok-partial"), sounds + QStringLiteral("/Plain")) && ok;
    for (const QString &name : {QStringLiteral("Glassy"), QStringLiteral("Plain")})       // two themes with names of their own
        ok = renameTheme(sounds + QLatin1Char('/') + name, name) && ok;
    ok = copyTree(fixtures + QStringLiteral("/bad-json"), sounds + QStringLiteral("/Broken")) && ok;
    return ok ? m_mockDrive->path() : QString();
}

bool SoundThemes::mockAddDriveTheme(const QString &folder, int files, qint64 bytes)
{
    if (!m_mock || !m_mockDrive || !isFolderName(folder))
        return false;
    const QString fixtures = fixturesDir();
    const QString target = m_mockDrive->path() + QStringLiteral("/Ruya Stick/RuyaOS/sounds/") + folder;
    if (fixtures.isEmpty() || !copyTree(fixtures + QStringLiteral("/ok-partial"), target) || !renameTheme(target, folder))
        return false;
    int have = 0;
    qint64 size = 0;
    QDirIterator it(target, QDir::Files | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        ++have;
        size += it.fileInfo().size();
    }
    if (files <= have || bytes < size)
        return false;
    // The extra files are empty but the first, which takes the rest of the bytes.
    for (int i = 0; i < files - have; ++i) {
        QFile f(target + QStringLiteral("/pad/%1.bin").arg(i, 3, 10, QLatin1Char('0')));
        if (!QDir().mkpath(QFileInfo(f).path()) || !f.open(QIODevice::WriteOnly))
            return false;
        if (i == 0 && f.write(QByteArray(int(bytes - size), 'x')) != bytes - size)
            return false;
    }
    return true;
}

void SoundThemes::mockSetCopyDelay(int ms)
{
    if (m_mock)
        m_copyDelayMs = qMax(0, ms);
}

void SoundThemes::mockReset()
{
    if (!m_mock)
        return;
    for (const QString &name : QDir(m_dir).entryList(QDir::Dirs | QDir::NoDotAndDotDot))
        QDir(m_dir + QLatin1Char('/') + name).removeRecursively();
    m_installed.clear();
    m_drive.clear();
    m_driveProblems.clear();
    m_mockDrive.reset();
    m_copyDelayMs = 0;
    reload();
}
