#include "PadDevices.h"

#include "PadMapper.h"

#include <QDir>
#include <QFile>
#include <QSocketNotifier>

#ifdef Q_OS_LINUX
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#endif

struct PadDevices::Pad
{
    int id = 0;
    QString path;
    int fd = -1;
    QSocketNotifier *notifier = nullptr;
    // SYN_DROPPED seen: the events up to the next SYN_REPORT are void, then the state is read again.
    bool dropping = false;
};

PadDevices::PadDevices(QObject *parent)
    : QObject(parent)
{
    m_timer.setInterval(1000);
    connect(&m_timer, &QTimer::timeout, this, &PadDevices::scan);
}

PadDevices::~PadDevices()
{
    // Closes the descriptors and says nothing: whoever listens may already be half destroyed.
    m_timer.stop();
    closeAll(false);
}

void PadDevices::start()
{
#ifdef Q_OS_LINUX
    if (m_timer.isActive())
        return;
    m_timer.start();
    scan();
#endif
}

void PadDevices::stop()
{
    m_timer.stop();
    closeAll(true);
}

void PadDevices::closeAll(bool report)
{
    const auto pads = m_pads.values();
    for (Pad *pad : pads)
        drop(pad, report);
    m_ignored.clear();
}

void PadDevices::mockPad(int id)
{
    auto *pad = new Pad;
    pad->id = id;
    pad->path = QStringLiteral("mock:%1").arg(id);
    m_pads.insert(pad->path, pad);
}

#ifdef Q_OS_LINUX
namespace {
// udev's database says what a node is (input_id sets ID_INPUT_JOYSTICK for a pad); the file is
// world-readable, so the shell needs no libudev for it.
bool isJoystick(const QString &path)
{
    struct stat st;
    if (::stat(QFile::encodeName(path).constData(), &st) != 0 || !S_ISCHR(st.st_mode))
        return false;
    QFile db(QStringLiteral("/run/udev/data/c%1:%2").arg(major(st.st_rdev)).arg(minor(st.st_rdev)));
    if (!db.open(QIODevice::ReadOnly))
        return false;
    while (!db.atEnd()) {
        if (db.readLine().trimmed() == "E:ID_INPUT_JOYSTICK=1")
            return true;
    }
    return false;
}

bool testBit(const unsigned char *bits, int code)
{
    return (bits[code / 8] >> (code % 8)) & 1;
}

// What the emergency table reads of a pad.
constexpr int Buttons[] = { PadMapper::BtnSouth,    PadMapper::BtnEast,      PadMapper::BtnStart,
                            PadMapper::BtnMode,     PadMapper::BtnDpadUp,    PadMapper::BtnDpadDown,
                            PadMapper::BtnDpadLeft, PadMapper::BtnDpadRight };
constexpr int Axes[] = { PadMapper::AbsX, PadMapper::AbsY, PadMapper::AbsHat0X, PadMapper::AbsHat0Y };
} // namespace
#endif

void PadDevices::scan()
{
#ifdef Q_OS_LINUX
    const QDir dir(QStringLiteral("/dev/input"));
    const QStringList nodes = dir.entryList({ QStringLiteral("event*") }, QDir::System | QDir::Files | QDir::NoDotAndDotDot);
    QSet<QString> present;
    for (const QString &node : nodes) {
        const QString path = dir.filePath(node);
        present.insert(path);
        if (!m_pads.contains(path) && !m_ignored.contains(path) && isJoystick(path))
            open(path);
    }
    // A node that went away may come back as another device under the same name.
    m_ignored.intersect(present);
#endif
}

void PadDevices::open(const QString &path)
{
#ifdef Q_OS_LINUX
    // Not readable (no ACL for ruya-shell): silently not ours.
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return;
    // ruya-input's virtual pads (phys "ruya-input/pad<n>", 06 section 3) are never read, whoever
    // may open them: they carry a game's input, not a physical pad's.
    char phys[256] = {};
    if (::ioctl(fd, EVIOCGPHYS(sizeof(phys) - 1), phys) >= 0 && std::strncmp(phys, "ruya-input/", 11) == 0) {
        ::close(fd);
        m_ignored.insert(path);
        return;
    }
    auto *pad = new Pad;
    pad->id = m_nextId++;
    pad->path = path;
    pad->fd = fd;
    m_pads.insert(path, pad);
    qInfo("ruya-shell: input fallback reads %s", qPrintable(path));
    for (int code : { ABS_X, ABS_Y }) {
        input_absinfo info;
        if (::ioctl(fd, EVIOCGABS(code), &info) == 0)
            emit axisRange(pad->id, code, info.minimum, info.maximum);
    }
    pad->notifier = new QSocketNotifier(fd, QSocketNotifier::Read, this);
    connect(pad->notifier, &QSocketNotifier::activated, this, [this, pad] { readFrom(pad); });
#else
    Q_UNUSED(path)
#endif
}

// The kernel's buffer overflowed (SYN_DROPPED): events were lost, so a release may be among them.
// The pad's state is read again and fed as events; the mapper presses what is newly down and
// releases what is no longer down, and ignores the rest.
void PadDevices::resync(Pad *pad)
{
#ifdef Q_OS_LINUX
    unsigned char keys[KEY_MAX / 8 + 1] = {};
    if (::ioctl(pad->fd, EVIOCGKEY(sizeof(keys)), keys) >= 0) {
        for (int code : Buttons)
            emit padEvent(pad->id, EV_KEY, code, testBit(keys, code) ? 1 : 0);
    }
    for (int code : Axes) {
        input_absinfo info;
        if (::ioctl(pad->fd, EVIOCGABS(code), &info) == 0 && info.maximum > info.minimum)
            emit padEvent(pad->id, EV_ABS, code, info.value);
    }
#else
    Q_UNUSED(pad)
#endif
}

void PadDevices::readFrom(Pad *pad)
{
#ifdef Q_OS_LINUX
    input_event buffer[64];
    for (;;) {
        const ssize_t n = ::read(pad->fd, buffer, sizeof(buffer));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno != EAGAIN)
                drop(pad); // ENODEV: the pad is gone
            return;
        }
        if (n == 0) {
            drop(pad);
            return;
        }
        const int count = static_cast<int>(n / static_cast<ssize_t>(sizeof(input_event)));
        for (int i = 0; i < count; ++i) {
            const input_event &ev = buffer[i];
            if (ev.type == EV_SYN) {
                if (ev.code == SYN_DROPPED)
                    pad->dropping = true;
                else if (ev.code == SYN_REPORT && pad->dropping) {
                    pad->dropping = false;
                    resync(pad);
                }
            } else if (!pad->dropping && (ev.type == EV_KEY || ev.type == EV_ABS)) {
                emit padEvent(pad->id, ev.type, ev.code, ev.value);
            }
        }
    }
#else
    Q_UNUSED(pad)
#endif
}

void PadDevices::drop(Pad *pad, bool report)
{
    m_pads.remove(pad->path);
    if (pad->notifier) {
        pad->notifier->setEnabled(false);
        pad->notifier->deleteLater();
    }
#ifdef Q_OS_LINUX
    if (pad->fd >= 0)
        ::close(pad->fd);
#endif
    const int id = pad->id;
    delete pad;
    if (report)
        emit gone(id);
}
