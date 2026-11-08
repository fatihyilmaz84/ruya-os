#include "SoundThemeCheck.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QTemporaryDir>
#include <QThread>
#include <QtMath>

#include <cstdlib>
#include <limits>
#include <memory>

namespace SoundTheme {

const QStringList &cueNames()
{
    static const QStringList names = {
        QStringLiteral("navigate"), QStringLiteral("select"), QStringLiteral("back"), QStringLiteral("error"),
        QStringLiteral("notification"), QStringLiteral("warning"), QStringLiteral("open"), QStringLiteral("close"),
        QStringLiteral("page"), QStringLiteral("volume"), QStringLiteral("startup"), QStringLiteral("toggle-on"),
        QStringLiteral("toggle-off"),
    };
    return names;
}

namespace {

bool isResource(const QString &dir)
{
    return dir.startsWith(QLatin1Char(':'));
}

quint16 le16(const QByteArray &d, int at)
{
    return quint16(quint8(d[at])) | (quint16(quint8(d[at + 1])) << 8);
}

quint32 le32(const QByteArray &d, int at)
{
    return quint32(le16(d, at)) | (quint32(le16(d, at + 2)) << 16);
}

qint64 le64(const QByteArray &d, int at)
{
    return qint64(quint64(le32(d, at)) | (quint64(le32(d, at + 4)) << 32));
}

QString kib(qint64 bytes)
{
    return QStringLiteral("%1 KB").arg((bytes + 1023) / 1024);
}

// A path from the manifest: relative, forward slashes, no `..`, no drive letter. Returns the file's
// path inside `dir`, or "" with `why` set.
QString resolve(const QString &dir, const QString &relative, QString *why)
{
    if (relative.isEmpty()) {
        *why = QStringLiteral("the file name is empty");
        return {};
    }
    if (relative.startsWith(QLatin1Char('/')) || relative.contains(QLatin1Char('\\')) || relative.contains(QLatin1Char(':'))
        || relative.contains(QChar(0))) {
        *why = QStringLiteral("'%1' is not a plain relative path").arg(relative);
        return {};
    }
    const QStringList parts = relative.split(QLatin1Char('/'));
    for (const QString &part : parts) {
        if (part.isEmpty() || part == QLatin1String(".") || part == QLatin1String("..")) {
            *why = QStringLiteral("'%1' leaves the theme folder or is not a plain path").arg(relative);
            return {};
        }
    }
    const QString path = dir + QLatin1Char('/') + relative;
    if (!isResource(dir)) {
        const QFileInfo info(path);
        if (info.isSymLink()) {
            *why = QStringLiteral("'%1' is a link").arg(relative);
            return {};
        }
        const QString real = info.canonicalFilePath();
        const QString root = QFileInfo(dir).canonicalFilePath();
        if (!real.isEmpty() && !real.startsWith(root + QLatin1Char('/'))) {
            *why = QStringLiteral("'%1' leaves the theme folder").arg(relative);
            return {};
        }
    }
    return path;
}

struct Audio
{
    int channels = 0;
    int rate = 0;
    qint64 durationMs = 0;
    double peak = 0;
};

// RIFF/WAVE, PCM 16-bit. Everything is read from `data` (at most MaxCueBytes).
bool parseWav(const QByteArray &data, Audio *out, QString *why)
{
    if (data.size() < 44 || data.left(4) != "RIFF" || data.mid(8, 4) != "WAVE") {
        *why = QStringLiteral("not a WAV file");
        return false;
    }
    // Offsets are qint64 and every chunk must lie inside the file before it is looked at: a hostile
    // size (0xFFFFFFF8, 0x80000000) must end in a refusal, never in a loop or an out-of-range read.
    qint64 at = 12;
    int channels = 0, rate = 0, bits = 0, format = 0;
    bool haveFmt = false;
    while (at + 8 <= data.size()) {
        const QByteArray id = data.mid(int(at), 4);
        const qint64 size = qint64(le32(data, int(at) + 4));
        const qint64 body = at + 8;
        if (size > data.size() - body) {
            *why = QStringLiteral("a chunk is cut short");
            return false;
        }
        if (id == "fmt ") {
            if (size < 16) {
                *why = QStringLiteral("the fmt chunk is cut short");
                return false;
            }
            format = le16(data, int(body));
            channels = le16(data, int(body) + 2);
            rate = int(qMin<quint32>(le32(data, int(body) + 4), 1000000));
            bits = le16(data, int(body) + 14);
            haveFmt = true;
        } else if (id == "data") {
            if (!haveFmt) {
                *why = QStringLiteral("the data chunk comes before the fmt chunk");
                return false;
            }
            if (format != 1 || bits != 16) {
                *why = QStringLiteral("only 16-bit PCM is accepted (format %1, %2 bits)").arg(format).arg(bits);
                return false;
            }
            if (channels < 1 || channels > 2) {
                *why = QStringLiteral("%1 channels (mono or stereo)").arg(channels);
                return false;
            }
            if (rate != CueSampleRate) {
                *why = QStringLiteral("sample rate %1 Hz (48000 Hz)").arg(rate);
                return false;
            }
            const int frames = int(size / (2 * channels));
            if (frames <= 0) {
                *why = QStringLiteral("no audio data");
                return false;
            }
            int peak = 0;
            const char *p = data.constData() + body;
            for (int i = 0; i < frames * channels; ++i) {
                const int v = std::abs(int(qint16(quint8(p[2 * i]) | (quint8(p[2 * i + 1]) << 8))));
                peak = qMax(peak, v);
            }
            out->channels = channels;
            out->rate = rate;
            out->durationMs = qint64(frames) * 1000 / rate;
            out->peak = peak / 32768.0;
            return true;
        }
        at = body + size + (size & 1);      // never moves back: size is >= 0 and inside the file
    }
    *why = QStringLiteral("no audio data");
    return false;
}

// FLAC: the STREAMINFO block at the head.
bool parseFlac(const QByteArray &head, Audio *out, QString *why)
{
    if (head.size() < 42 || head.left(4) != "fLaC" || (quint8(head[4]) & 0x7F) != 0 || head.mid(5, 3) != QByteArray("\0\0\x22", 3)) {
        *why = QStringLiteral("not a FLAC file");
        return false;
    }
    const quint64 packed = (quint64(quint8(head[18])) << 56) | (quint64(quint8(head[19])) << 48) | (quint64(quint8(head[20])) << 40)
        | (quint64(quint8(head[21])) << 32) | (quint64(quint8(head[22])) << 24) | (quint64(quint8(head[23])) << 16)
        | (quint64(quint8(head[24])) << 8) | quint64(quint8(head[25]));
    const quint64 rate = packed >> 44;
    const int channels = int((packed >> 41) & 7) + 1;
    const quint64 total = packed & ((quint64(1) << 36) - 1);
    if (rate == 0 || total == 0) {
        *why = QStringLiteral("the FLAC header does not give a sample rate and length");
        return false;
    }
    out->rate = int(rate);
    out->channels = channels;
    out->durationMs = qint64(total * 1000 / rate);
    return true;
}

// Ogg Vorbis or Ogg Opus: the identification header of the first page, the granule position of the last.
bool parseOgg(const QByteArray &head, const QByteArray &tail, Audio *out, QString *why)
{
    if (head.size() < 27 || head.left(4) != "OggS") {
        *why = QStringLiteral("not an Ogg file");
        return false;
    }
    const int segments = quint8(head[26]);
    const int packet = 27 + segments;
    if (head.size() < packet + 19) {
        *why = QStringLiteral("the Ogg header is cut short");
        return false;
    }
    int rate = 0, channels = 0;
    qint64 skip = 0;
    if (head.mid(packet, 7) == "\x01vorbis") {
        if (le32(head, packet + 7) != 0) {
            *why = QStringLiteral("unknown Vorbis version");
            return false;
        }
        channels = quint8(head[packet + 11]);
        rate = int(qMin<quint32>(le32(head, packet + 12), 1000000));
    } else if (head.mid(packet, 8) == "OpusHead") {
        channels = quint8(head[packet + 9]);
        skip = le16(head, packet + 10);
        rate = 48000;      // Opus always decodes at 48 kHz; the field in the header is only the source rate
    } else {
        *why = QStringLiteral("the Ogg stream is neither Vorbis nor Opus");
        return false;
    }
    const int last = int(tail.lastIndexOf("OggS"));
    if (last < 0 || tail.size() < last + 14) {
        *why = QStringLiteral("no Ogg page with a length at the end");
        return false;
    }
    const qint64 granule = le64(tail, last + 6);
    // A day of audio is far more than any theme may hold; anything bigger (or negative) is a damaged
    // header, and this also keeps the arithmetic below inside 64 bits.
    if (granule <= skip || rate <= 0 || granule > qint64(rate) * 86400) {
        *why = QStringLiteral("the Ogg stream has no usable length");
        return false;
    }
    out->rate = rate;
    out->channels = channels;
    out->durationMs = (granule - skip) * 1000 / rate;
    return true;
}

// A number from the manifest as whole milliseconds. Converting a double that does not fit into 64 bits is
// undefined behaviour, so it is clamped first (to far more than any file's length: the verdict stays "not
// inside the file", and the message names a number that can be printed).
constexpr double MaxManifestMs = 1e15;
qint64 clampedMs(double value)
{
    if (!(value == value))
        return 0;
    return qint64(qBound(-MaxManifestMs, value, MaxManifestMs));
}

bool hasExtension(const QString &path, const QStringList &allowed)
{
    const QString lower = path.toLower();
    for (const QString &ext : allowed) {
        if (lower.endsWith(QLatin1Char('.') + ext))
            return true;
    }
    return false;
}

bool readHeadAndTail(const QString &path, QByteArray *head, QByteArray *tail)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return false;
    *head = file.read(4096);
    const qint64 size = file.size();
    const qint64 from = qMax<qint64>(0, size - 65536);
    if (!file.seek(from))
        return false;
    *tail = file.read(65536);
    return true;
}

} // namespace

Result check(const QString &dir)
{
    Result r;
    const auto fail = [&r](const QString &message) { r.problems.append(message); };

    if (dir.isEmpty() || !QFileInfo(dir).isDir()) {
        fail(QStringLiteral("the folder does not exist"));
        return r;
    }
    const QString manifestPath = dir + QStringLiteral("/theme.json");
    const QFileInfo manifestInfo(manifestPath);
    if (!manifestInfo.isFile()) {
        fail(QStringLiteral("theme.json is missing"));
        return r;
    }
    if (manifestInfo.size() > MaxManifestBytes) {
        fail(QStringLiteral("theme.json is larger than %1").arg(kib(MaxManifestBytes)));
        return r;
    }
    QFile manifestFile(manifestPath);
    if (!manifestFile.open(QIODevice::ReadOnly)) {
        fail(QStringLiteral("theme.json cannot be read"));
        return r;
    }
    QJsonParseError parseError;
    const QByteArray manifestBytes = manifestFile.read(MaxManifestBytes + 1);       // never more than the limit, whatever the size said
    if (manifestBytes.size() > MaxManifestBytes) {
        fail(QStringLiteral("theme.json is larger than %1").arg(kib(MaxManifestBytes)));
        return r;
    }
    const QJsonDocument doc = QJsonDocument::fromJson(manifestBytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
        fail(QStringLiteral("theme.json is not a JSON object"));
        return r;
    }
    const QJsonObject root = doc.object();

    const auto text = [&](const char *key, int maxLength, bool required) {
        const QJsonValue v = root.value(QLatin1String(key));
        if (!v.isString() || v.toString().trimmed().isEmpty() || v.toString().size() > maxLength) {
            if (required || !v.isUndefined())
                fail(QStringLiteral("'%1' must be a text of 1 to %2 characters").arg(QLatin1String(key)).arg(maxLength));
            return QString();
        }
        return v.toString().trimmed();
    };
    Manifest &m = r.manifest;
    m.name = text("name", 48, true);
    m.author = text("author", 80, true);
    m.licence = text("licence", 96, true);
    m.version = text("version", 32, true);
    static const QRegularExpression spdx(QStringLiteral("^[A-Za-z0-9.+-]{2,40}( (AND|OR|WITH) [A-Za-z0-9.+-]{2,40})*$"));
    if (!m.licence.isEmpty() && !spdx.match(m.licence).hasMatch())
        fail(QStringLiteral("'licence' must be an SPDX identifier such as CC0-1.0 or CC-BY-4.0"));
    static const QRegularExpression semver(QStringLiteral("^\\d+\\.\\d+\\.\\d+([-+][0-9A-Za-z.-]+)?$"));
    if (!m.version.isEmpty() && !semver.match(m.version).hasMatch())
        fail(QStringLiteral("'version' must look like 1.0.0"));

    // ---- cues ----
    const QJsonValue cuesValue = root.value(QStringLiteral("cues"));
    if (!cuesValue.isObject()) {
        fail(QStringLiteral("'cues' must be an object of cue name to file"));
    } else {
        const QJsonObject cues = cuesValue.toObject();
        if (cues.size() > MaxCues)
            fail(QStringLiteral("more than %1 cues").arg(MaxCues));
        for (auto it = cues.begin(); it != cues.end() && cues.size() <= MaxCues; ++it) {
            const QString cue = it.key();
            const QString label = QStringLiteral("cue '%1': ").arg(cue);
            if (!cueNames().contains(cue)) {
                r.warnings.append(QStringLiteral("'%1' is not a cue name this version of RuyaOS plays").arg(cue));
                continue;
            }
            if (!it.value().isString()) {
                fail(label + QStringLiteral("the value must be a file name"));
                continue;
            }
            QString why;
            const QString path = resolve(dir, it.value().toString(), &why);
            if (path.isEmpty()) {
                fail(label + why);
                continue;
            }
            if (!hasExtension(path, {QStringLiteral("wav")})) {
                fail(label + QStringLiteral("unknown extension (cues are .wav)"));
                continue;
            }
            const QFileInfo info(path);
            if (!info.isFile()) {
                fail(label + QStringLiteral("the file '%1' is missing").arg(it.value().toString()));
                continue;
            }
            if (info.size() > MaxCueBytes) {
                fail(label + QStringLiteral("the file is larger than %1 (%2)").arg(kib(MaxCueBytes), kib(info.size())));
                continue;
            }
            QFile file(path);
            if (!file.open(QIODevice::ReadOnly)) {
                fail(label + QStringLiteral("the file cannot be read"));
                continue;
            }
            Audio audio;
            const QByteArray wav = file.read(MaxCueBytes + 1);
            if (wav.size() > MaxCueBytes) {
                fail(label + QStringLiteral("the file is larger than %1").arg(kib(MaxCueBytes)));
                continue;
            }
            if (!parseWav(wav, &audio, &why)) {
                fail(label + why);
                continue;
            }
            if (audio.durationMs > MaxCueMs) {
                fail(label + QStringLiteral("longer than 1.5 s (%1 ms)").arg(audio.durationMs));
                continue;
            }
            if (audio.peak > PeakLimit) {
                fail(label + QStringLiteral("peak above -3 dBFS"));
                continue;
            }
            m.cues.insert(cue, path);
            m.cueMs.insert(cue, audio.durationMs);
        }
    }

    // ---- ambient ----
    const QJsonValue ambientValue = root.value(QStringLiteral("ambient"));
    if (!ambientValue.isUndefined()) {
        const QString label = QStringLiteral("ambient: ");
        if (!ambientValue.isObject()) {
            fail(label + QStringLiteral("must be an object with a file"));
        } else {
            const QJsonObject ambient = ambientValue.toObject();
            QString why;
            const QJsonValue fileValue = ambient.value(QStringLiteral("file"));
            const QString path = fileValue.isString() ? resolve(dir, fileValue.toString(), &why) : QString();
            double gain = 1.0;
            if (ambient.contains(QStringLiteral("gain"))) {
                gain = ambient.value(QStringLiteral("gain")).toDouble(-1);
                if (!(gain >= 0.0 && gain <= 1.0))
                    fail(label + QStringLiteral("'gain' must be between 0 and 1"));
            }
            if (!fileValue.isString()) {
                fail(label + QStringLiteral("'file' must be a file name"));
            } else if (path.isEmpty()) {
                fail(label + why);
            } else if (!hasExtension(path, {QStringLiteral("ogg"), QStringLiteral("opus"), QStringLiteral("flac")})) {
                fail(label + QStringLiteral("unknown extension (.ogg, .opus or .flac)"));
            } else if (!QFileInfo(path).isFile()) {
                fail(label + QStringLiteral("the file '%1' is missing").arg(fileValue.toString()));
            } else if (QFileInfo(path).size() > MaxAmbientBytes) {
                fail(label + QStringLiteral("the file is larger than 3 MB"));
            } else {
                QByteArray head, tail;
                Audio audio;
                bool parsed = false;
                if (!readHeadAndTail(path, &head, &tail)) {
                    fail(label + QStringLiteral("the file cannot be read"));
                } else if (hasExtension(path, {QStringLiteral("flac")})) {
                    parsed = parseFlac(head, &audio, &why);
                } else {
                    parsed = parseOgg(head, tail, &audio, &why);
                }
                if (!parsed && !why.isEmpty()) {
                    fail(label + why);
                } else if (parsed) {
                    if (audio.channels < 1 || audio.channels > 2 || audio.rate < 8000 || audio.rate > 96000) {
                        fail(label + QStringLiteral("%1 channels at %2 Hz (mono or stereo, 8 to 96 kHz)").arg(audio.channels).arg(audio.rate));
                    } else {
                        qint64 start = 0, end = audio.durationMs;
                        const QJsonValue loop = ambient.value(QStringLiteral("loop"));
                        bool loopOk = true;
                        if (!loop.isUndefined()) {
                            const QJsonObject o = loop.toObject();
                            if (!loop.isObject() || !o.value(QStringLiteral("start")).isDouble() || !o.value(QStringLiteral("end")).isDouble()) {
                                fail(label + QStringLiteral("'loop' needs a numeric start and end in ms"));
                                loopOk = false;
                            } else {
                                start = clampedMs(o.value(QStringLiteral("start")).toDouble());
                                end = clampedMs(o.value(QStringLiteral("end")).toDouble());
                            }
                        }
                        if (loopOk && (start < 0 || end > audio.durationMs || end <= start)) {
                            fail(label + QStringLiteral("the loop (%1 to %2 ms) is not inside the file (%3 ms)").arg(start).arg(end).arg(audio.durationMs));
                            loopOk = false;
                        }
                        if (loopOk && end - start < MinLoopMs) {
                            fail(label + QStringLiteral("the loop is shorter than 5 s"));
                            loopOk = false;
                        }
                        if (loopOk && gain >= 0.0 && gain <= 1.0) {
                            m.hasAmbient = true;
                            m.ambient.file = path;
                            m.ambient.loopStartMs = start;
                            m.ambient.loopEndMs = end;
                            m.ambient.gain = gain;
                            m.ambient.durationMs = audio.durationMs;
                        }
                    }
                }
            }
        }
    }

    if (!QFileInfo::exists(dir + QStringLiteral("/README.md")) && !QFileInfo::exists(dir + QStringLiteral("/README.txt"))
        && !QFileInfo::exists(dir + QStringLiteral("/README")))
        r.warnings.append(QStringLiteral("there is no README"));

    r.ok = r.problems.isEmpty();
    if (!r.ok)
        m = Manifest();
    return r;
}

// ---------------------------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------------------------
namespace {

void put16(QByteArray &b, quint16 v)
{
    b.append(char(v & 0xFF));
    b.append(char(v >> 8));
}

void put32(QByteArray &b, quint32 v)
{
    put16(b, quint16(v & 0xFFFF));
    put16(b, quint16(v >> 16));
}

QByteArray makeWav(int ms, int rate, int channels, double amplitude)
{
    const int frames = int(qint64(ms) * rate / 1000);
    QByteArray data;
    for (int i = 0; i < frames; ++i) {
        const qint16 v = qint16(qRound(amplitude * 32767.0 * qSin(2 * M_PI * 440.0 * i / rate)));
        for (int c = 0; c < channels; ++c)
            put16(data, quint16(v));
    }
    QByteArray b("RIFF");
    put32(b, quint32(36 + data.size()));
    b.append("WAVEfmt ");
    put32(b, 16);
    put16(b, 1);
    put16(b, quint16(channels));
    put32(b, quint32(rate));
    put32(b, quint32(rate * channels * 2));
    put16(b, quint16(channels * 2));
    put16(b, 16);
    b.append("data");
    put32(b, quint32(data.size()));
    return b + data;
}

// A valid WAV with one more chunk (id, a declared size that need not be true, a payload) between the fmt and
// the data chunk, where a hostile file hides its trick (offset 36).
QByteArray wavWithChunk(const QByteArray &wav, const QByteArray &id, quint32 declared, const QByteArray &payload)
{
    QByteArray chunk = id;
    put32(chunk, declared);
    chunk.append(payload);
    return wav.left(36) + chunk + wav.mid(36);
}

// A FLAC file that is only a STREAMINFO header (enough for the checker, which reads data, never decodes).
QByteArray makeFlacHeader(int rate, int channels, quint64 totalSamples, qint64 padTo = 0)
{
    QByteArray b("fLaC");
    b.append(char(0x80));
    b.append(QByteArray("\0\0\x22", 3));
    b.append(QByteArray("\x10\x00\x10\x00", 4));    // block size 4096
    b.append(QByteArray(6, '\0'));                  // frame sizes unknown
    const quint64 packed = (quint64(rate) << 44) | (quint64(channels - 1) << 41) | (quint64(15) << 36) | totalSamples;
    for (int shift = 56; shift >= 0; shift -= 8)
        b.append(char((packed >> shift) & 0xFF));
    b.append(QByteArray(16, '\0'));                 // MD5
    if (padTo > b.size())
        b.append(QByteArray(int(padTo - b.size()), '\0'));
    return b;
}

QByteArray oggPage(quint8 type, qint64 granule, const QByteArray &packet)
{
    QByteArray b("OggS");
    b.append(char(0));
    b.append(char(type));
    for (int i = 0; i < 8; ++i)
        b.append(char((granule >> (8 * i)) & 0xFF));
    b.append(QByteArray(12, '\0'));                 // serial, sequence, checksum (not checked: data only)
    if (packet.isEmpty()) {
        b.append(char(0));
    } else {
        b.append(char(1));
        b.append(char(packet.size()));
        b.append(packet);
    }
    return b;
}

QByteArray makeOgg(int rate, int channels, qint64 granule)
{
    QByteArray ident("\x01vorbis");
    put32(ident, 0);
    ident.append(char(channels));
    put32(ident, quint32(rate));
    ident.append(QByteArray(10, '\0'));
    return oggPage(2, 0, ident) + oggPage(4, granule, QByteArray());
}

bool writeFile(const QString &path, const QByteArray &data)
{
    QDir().mkpath(QFileInfo(path).path());
    QFile f(path);
    return f.open(QIODevice::WriteOnly) && f.write(data) == data.size();
}

// A manifest with the given cue map and ambient; `extra` replaces whole keys.
QByteArray manifest(const QJsonObject &cues, const QJsonObject &ambient, const QJsonObject &override = {})
{
    QJsonObject o{{QStringLiteral("name"), QStringLiteral("Fixture")}, {QStringLiteral("author"), QStringLiteral("Tests")},
                  {QStringLiteral("licence"), QStringLiteral("CC0-1.0")}, {QStringLiteral("version"), QStringLiteral("1.0.0")},
                  {QStringLiteral("cues"), cues}};
    if (!ambient.isEmpty())
        o.insert(QStringLiteral("ambient"), ambient);
    for (auto it = override.begin(); it != override.end(); ++it)
        o.insert(it.key(), it.value());
    return QJsonDocument(o).toJson();
}

QJsonObject ambientOf(const QString &file, qint64 start, qint64 end, double gain = 0.5)
{
    return {{QStringLiteral("file"), file}, {QStringLiteral("gain"), gain},
            {QStringLiteral("loop"), QJsonObject{{QStringLiteral("start"), double(start)}, {QStringLiteral("end"), double(end)}}}};
}

} // namespace

QList<FixtureCase> fixtureCases()
{
    return {
        {QStringLiteral("ok-full"), true, {}},
        {QStringLiteral("ok-partial"), true, {}},
        {QStringLiteral("ok-ogg"), true, {}},
        {QStringLiteral("ok-unknown-cue"), true, {}},
        {QStringLiteral("bad-no-manifest"), false, QStringLiteral("theme.json is missing")},
        {QStringLiteral("bad-json"), false, QStringLiteral("not a JSON object")},
        {QStringLiteral("bad-no-name"), false, QStringLiteral("'name'")},
        {QStringLiteral("bad-licence"), false, QStringLiteral("SPDX")},
        {QStringLiteral("bad-oversize-cue"), false, QStringLiteral("larger than 200 KB")},
        {QStringLiteral("bad-long-cue"), false, QStringLiteral("longer than 1.5 s")},
        {QStringLiteral("bad-loud-cue"), false, QStringLiteral("peak above -3 dBFS")},
        {QStringLiteral("bad-cue-rate"), false, QStringLiteral("sample rate 44100")},
        {QStringLiteral("bad-cue-extension"), false, QStringLiteral("unknown extension")},
        {QStringLiteral("bad-cue-missing"), false, QStringLiteral("is missing")},
        {QStringLiteral("bad-cue-not-wav"), false, QStringLiteral("not a WAV file")},
        {QStringLiteral("bad-escape"), false, QStringLiteral("leaves the theme folder")},
        {QStringLiteral("bad-absolute"), false, QStringLiteral("not a plain relative path")},
        {QStringLiteral("bad-loop-outside"), false, QStringLiteral("not inside the file")},
        {QStringLiteral("bad-loop-short"), false, QStringLiteral("shorter than 5 s")},
        {QStringLiteral("bad-ambient-oversize"), false, QStringLiteral("larger than 3 MB")},
        {QStringLiteral("bad-ambient-extension"), false, QStringLiteral("unknown extension")},
        {QStringLiteral("bad-ambient-not-audio"), false, QStringLiteral("not a FLAC file")},
        {QStringLiteral("bad-ambient-gain"), false, QStringLiteral("'gain'")},
        {QStringLiteral("bad-wav-chunk-loop"), false, QStringLiteral("a chunk is cut short")},       // size 0xFFFFFFF8 once looped forever
        {QStringLiteral("bad-wav-chunk-negative"), false, QStringLiteral("a chunk is cut short")},   // size 0x80000000 once read out of range
        {QStringLiteral("ok-wav-extra-chunk"), true, {}},
        {QStringLiteral("bad-granule-overflow"), false, QStringLiteral("no usable length")},          // an Ogg granule of 2^63 - 1
        {QStringLiteral("bad-loop-overflow"), false, QStringLiteral("0 to 1000000000000000 ms")},   // a loop end of 1e300, clamped before the cast
    };
}

bool writeFixtures(const QString &root)
{
    bool ok = true;
    const auto put = [&](const QString &theme, const QString &file, const QByteArray &data) {
        ok = writeFile(root + QLatin1Char('/') + theme + QLatin1Char('/') + file, data) && ok;
    };
    const QByteArray tone = makeWav(120, CueSampleRate, 1, 0.4);
    QJsonObject allCues;
    for (const QString &cue : cueNames())
        allCues.insert(cue, cue + QStringLiteral(".wav"));
    const auto putAllCues = [&](const QString &theme) {
        for (const QString &cue : cueNames())
            put(theme, cue + QStringLiteral(".wav"), tone);
        put(theme, QStringLiteral("README.md"), "fixture");
    };
    const QByteArray flac = makeFlacHeader(24000, 1, 24000 * 10);        // 10 s

    putAllCues(QStringLiteral("ok-full"));
    put(QStringLiteral("ok-full"), QStringLiteral("ambient.flac"), flac);
    put(QStringLiteral("ok-full"), QStringLiteral("theme.json"), manifest(allCues, ambientOf(QStringLiteral("ambient.flac"), 0, 10000)));

    put(QStringLiteral("ok-partial"), QStringLiteral("select.wav"), tone);
    put(QStringLiteral("ok-partial"), QStringLiteral("sub/back.wav"), makeWav(200, CueSampleRate, 2, 0.5));
    put(QStringLiteral("ok-partial"), QStringLiteral("theme.json"),
        manifest({{QStringLiteral("select"), QStringLiteral("select.wav")}, {QStringLiteral("back"), QStringLiteral("sub/back.wav")}}, {}));

    put(QStringLiteral("ok-ogg"), QStringLiteral("select.wav"), tone);
    put(QStringLiteral("ok-ogg"), QStringLiteral("pad.ogg"), makeOgg(48000, 2, 48000LL * 20));
    put(QStringLiteral("ok-ogg"), QStringLiteral("theme.json"),
        manifest({{QStringLiteral("select"), QStringLiteral("select.wav")}}, ambientOf(QStringLiteral("pad.ogg"), 1000, 19000)));

    put(QStringLiteral("ok-unknown-cue"), QStringLiteral("select.wav"), tone);
    put(QStringLiteral("ok-unknown-cue"), QStringLiteral("theme.json"),
        manifest({{QStringLiteral("select"), QStringLiteral("select.wav")}, {QStringLiteral("fanfare"), QStringLiteral("select.wav")}}, {}));

    const QJsonObject selectOnly{{QStringLiteral("select"), QStringLiteral("select.wav")}};
    const auto simple = [&](const QString &theme, const QByteArray &wav, const QJsonObject &override = {}) {
        put(theme, QStringLiteral("select.wav"), wav);
        put(theme, QStringLiteral("theme.json"), manifest(selectOnly, {}, override));
    };

    put(QStringLiteral("bad-json"), QStringLiteral("theme.json"), "{ not json");
    ok = QDir().mkpath(root + QStringLiteral("/bad-no-manifest")) && ok;
    simple(QStringLiteral("bad-no-name"), tone, {{QStringLiteral("name"), QString()}});
    simple(QStringLiteral("bad-licence"), tone, {{QStringLiteral("licence"), QStringLiteral("free to use!")}});
    simple(QStringLiteral("bad-oversize-cue"), makeWav(1400, CueSampleRate, 2, 0.4));       // 268 KB
    simple(QStringLiteral("bad-long-cue"), makeWav(1600, CueSampleRate, 1, 0.4));           // 1.6 s
    simple(QStringLiteral("bad-loud-cue"), makeWav(100, CueSampleRate, 1, 0.99));
    simple(QStringLiteral("bad-cue-rate"), makeWav(100, 44100, 1, 0.4));
    simple(QStringLiteral("bad-cue-not-wav"), "this is not audio at all, only text, long enough to look like a header....");
    put(QStringLiteral("bad-cue-extension"), QStringLiteral("select.mp3"), tone);
    put(QStringLiteral("bad-cue-extension"), QStringLiteral("theme.json"), manifest({{QStringLiteral("select"), QStringLiteral("select.mp3")}}, {}));
    put(QStringLiteral("bad-cue-missing"), QStringLiteral("theme.json"), manifest(selectOnly, {}));
    put(QStringLiteral("bad-escape"), QStringLiteral("outside.wav"), tone);       // next to the theme folder, not in it
    ok = writeFile(root + QStringLiteral("/outside.wav"), tone) && ok;
    put(QStringLiteral("bad-escape"), QStringLiteral("theme.json"), manifest({{QStringLiteral("select"), QStringLiteral("../outside.wav")}}, {}));
    put(QStringLiteral("bad-absolute"), QStringLiteral("theme.json"), manifest({{QStringLiteral("select"), root + QStringLiteral("/outside.wav")}}, {}));
    const auto withAmbient = [&](const QString &theme, const QString &file, const QByteArray &audio, const QJsonObject &ambient) {
        put(theme, QStringLiteral("select.wav"), tone);
        put(theme, file, audio);
        put(theme, QStringLiteral("theme.json"), manifest(selectOnly, ambient));
    };
    withAmbient(QStringLiteral("bad-loop-outside"), QStringLiteral("ambient.flac"), flac, ambientOf(QStringLiteral("ambient.flac"), 0, 12000));
    withAmbient(QStringLiteral("bad-loop-short"), QStringLiteral("ambient.flac"), flac, ambientOf(QStringLiteral("ambient.flac"), 2000, 4000));
    withAmbient(QStringLiteral("bad-ambient-oversize"), QStringLiteral("ambient.flac"), makeFlacHeader(24000, 1, 24000 * 10, MaxAmbientBytes + 1),
                ambientOf(QStringLiteral("ambient.flac"), 0, 10000));
    withAmbient(QStringLiteral("bad-ambient-extension"), QStringLiteral("ambient.mp3"), flac, ambientOf(QStringLiteral("ambient.mp3"), 0, 10000));
    withAmbient(QStringLiteral("bad-ambient-not-audio"), QStringLiteral("ambient.flac"), QByteArray(100, 'x'),
                ambientOf(QStringLiteral("ambient.flac"), 0, 10000));
    simple(QStringLiteral("bad-wav-chunk-loop"), wavWithChunk(tone, "LIST", 0xFFFFFFF8u, QByteArray(4, 'x')));
    simple(QStringLiteral("bad-wav-chunk-negative"), wavWithChunk(tone, "LIST", 0x80000000u, QByteArray(4, 'x')));
    simple(QStringLiteral("ok-wav-extra-chunk"), wavWithChunk(tone, "LIST", 4, QByteArray(4, 'x')));
    withAmbient(QStringLiteral("bad-ambient-gain"), QStringLiteral("ambient.flac"), flac, ambientOf(QStringLiteral("ambient.flac"), 0, 10000, 3.0));
    withAmbient(QStringLiteral("bad-granule-overflow"), QStringLiteral("pad.ogg"), makeOgg(48000, 2, std::numeric_limits<qint64>::max()),
                ambientOf(QStringLiteral("pad.ogg"), 0, 10000));
    QJsonObject huge = ambientOf(QStringLiteral("ambient.flac"), 0, 10000);
    huge.insert(QStringLiteral("loop"), QJsonObject{{QStringLiteral("start"), 0.0}, {QStringLiteral("end"), 1e300}});
    withAmbient(QStringLiteral("bad-loop-overflow"), QStringLiteral("ambient.flac"), flac, huge);
    return ok;
}

// ---------------------------------------------------------------------------------------------
// Fuzzing the parsers (T-227 round 2): a hostile file must always end in a verdict.
// ---------------------------------------------------------------------------------------------
namespace {

// Every mutation of the first 128 bytes of `seed`: cut at each length, one byte set to 0x00 and 0xFF, and
// each 4-byte field (at every offset, little- and big-endian) set to 0, 1, 0x7fffffff, 0x80000000, 0xfffffff8.
// `run` gets each mutated file; the count of files tried is returned.
template<typename Run>
int mutations(const QByteArray &seed, Run run)
{
    int cases = 0;
    const int limit = qMin<int>(seed.size(), 128);
    for (int n = 0; n <= limit; ++n) {
        run(seed.left(n));
        ++cases;
    }
    for (int o = 0; o < limit; ++o) {
        for (char v : {char(0x00), char(0xFF)}) {
            QByteArray b = seed;
            b[o] = v;
            run(b);
            ++cases;
        }
    }
    static const quint32 values[] = {0u, 1u, 0x7fffffffu, 0x80000000u, 0xfffffff8u};
    for (int o = 0; o + 4 <= limit; ++o) {
        for (quint32 v : values) {
            for (bool bigEndian : {false, true}) {
                QByteArray b = seed;
                for (int i = 0; i < 4; ++i)
                    b[o + i] = char((v >> (bigEndian ? 8 * (3 - i) : 8 * i)) & 0xFF);
                run(b);
                ++cases;
            }
        }
    }
    return cases;
}

} // namespace

bool fuzz(QString *problem, int *cases, int timeoutMs)
{
    struct State
    {
        bool done = false;
        int cases = 0;
        QString problem;
    };
    auto state = std::make_shared<State>();
    QThread *thread = QThread::create([state] {
        QTemporaryDir dir;
        if (!dir.isValid()) {
            state->problem = QStringLiteral("no temporary directory");
            state->done = true;
            return;
        }
        const QString folder = dir.path();
        const QByteArray plain = makeWav(10, CueSampleRate, 1, 0.4);
        const QByteArray wav = wavWithChunk(plain, "LIST", 4, QByteArray(4, 'x'));
        const QByteArray ogg = makeOgg(48000, 2, 48000LL * 20);
        const QByteArray flac = makeFlacHeader(24000, 1, 24000 * 10);
        const auto writeTheme = [&folder](const QByteArray &cue, const QByteArray &ambient, const QString &ambientName) {
            writeFile(folder + QStringLiteral("/select.wav"), cue);
            QJsonObject cues{{QStringLiteral("select"), QStringLiteral("select.wav")}};
            QJsonObject amb;
            if (!ambientName.isEmpty()) {
                writeFile(folder + QLatin1Char('/') + ambientName, ambient);
                amb = ambientOf(ambientName, 0, 10000);
            }
            writeFile(folder + QStringLiteral("/theme.json"), manifest(cues, amb));
        };
        // The file under test is rewritten for each mutation; the verdict is not looked at, only that one comes.
        state->cases += mutations(wav, [&](const QByteArray &b) { writeTheme(b, QByteArray(), QString()); (void)check(folder); });
        state->cases += mutations(ogg, [&](const QByteArray &b) { writeTheme(plain, b, QStringLiteral("pad.ogg")); (void)check(folder); });
        state->cases += mutations(flac, [&](const QByteArray &b) { writeTheme(plain, b, QStringLiteral("pad.flac")); (void)check(folder); });
        state->done = true;
    });
    thread->start();
    const bool finished = thread->wait(timeoutMs);
    if (!finished) {
        thread->terminate();                      // a hang is the failure being looked for; do not wait for it
        thread->wait(2000);
        *problem = QStringLiteral("the checker did not return within %1 ms").arg(timeoutMs);
        *cases = state->cases;
        return false;
    }
    delete thread;
    *cases = state->cases;
    *problem = state->problem;
    return state->done && state->problem.isEmpty();
}

} // namespace SoundTheme
