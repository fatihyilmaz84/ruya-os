#include "PadDevices.h"

#include <QDir>
#include <QFile>
#include <QSocketNotifier>

#ifdef Q_OS_LINUX
#include <cerrno>
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
};

PadDevices::PadDevices(QObject *parent)
    : QObject(parent)
{
    m_timer.setInterval(1000);
    connect(&m_timer, &QTimer::timeout, this, &PadDevices::scan);
}

PadDevices::~PadDevices()
{
    stop();
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
    const auto pads = m_pads.values();
    for (Pad *pad : pads)
        drop(pad);
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
} // namespace
#endif

void PadDevices::scan()
{
#ifdef Q_OS_LINUX
    const QDir dir(QStringLiteral("/dev/input"));
    const QStringList nodes = dir.entryList({ QStringLiteral("event*") }, QDir::System | QDir::Files | QDir::NoDotAndDotDot);
    for (const QString &node : nodes) {
        const QString path = dir.filePath(node);
        if (!m_pads.contains(path) && isJoystick(path))
            open(path);
    }
#endif
}

void PadDevices::open(const QString &path)
{
#ifdef Q_OS_LINUX
    // Not readable (no ACL for ruya-shell, as with a virtual pad): silently not ours.
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return;
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
            if (buffer[i].type == EV_KEY || buffer[i].type == EV_ABS)
                emit padEvent(pad->id, buffer[i].type, buffer[i].code, buffer[i].value);
        }
    }
#else
    Q_UNUSED(pad)
#endif
}

void PadDevices::drop(Pad *pad)
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
    emit gone(id);
}
