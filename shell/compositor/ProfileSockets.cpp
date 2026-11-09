#include "ProfileSockets.h"

#include <QFile>
#include <QtGlobal>

#include <cerrno>
#include <cstdint>
#include <cstring>

#include <pwd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/xattr.h>
#include <unistd.h>

namespace {

// The kernel's POSIX ACL xattr format (linux/posix_acl_xattr.h), written directly so the shell
// needs no libacl: a version word, then entries sorted by tag (and by id within ACL_USER).
struct AclEntry
{
    uint16_t tag;
    uint16_t perm;
    uint32_t id;
};
static_assert(sizeof(AclEntry) == 8, "posix_acl_xattr_entry is 8 bytes");
constexpr uint32_t kAclVersion = 2;
constexpr uint16_t kUserObj = 0x01, kUser = 0x02, kGroupObj = 0x04, kMask = 0x10, kOther = 0x20;
constexpr uint32_t kNoId = 0xffffffffu;
constexpr uint16_t kRw = 4 | 2;

// owner rw-, user:<uid> rw-, group ---, mask rw-, other ---.
bool setUserAcl(const char *path, uid_t uid)
{
    const AclEntry entries[] = {
        { kUserObj, kRw, kNoId },
        { kUser, kRw, static_cast<uint32_t>(uid) },
        { kGroupObj, 0, kNoId },
        { kMask, kRw, kNoId },
        { kOther, 0, kNoId },
    };
    char buf[sizeof(kAclVersion) + sizeof(entries)];
    std::memcpy(buf, &kAclVersion, sizeof(kAclVersion));
    std::memcpy(buf + sizeof(kAclVersion), entries, sizeof(entries));
    return ::setxattr(path, "system.posix_acl_access", buf, sizeof(buf), 0) == 0;
}

bool plainName(const QString &user)
{
    return !user.isEmpty() && !user.startsWith(QLatin1Char('.')) && !user.contains(QLatin1Char('/'));
}

} // namespace

ProfileSockets::ProfileSockets(QObject *parent) : QObject(parent) {}

void ProfileSockets::setCompositor(QWaylandCompositor *compositor)
{
    if (m_compositor == compositor)
        return;
    m_compositor = compositor;
    emit compositorChanged();
}

void ProfileSockets::setDirectory(const QString &directory)
{
    if (m_directory == directory)
        return;
    m_directory = directory;
    emit directoryChanged();
}

QString ProfileSockets::pathOf(const QString &user) const
{
    return m_paths.value(user);
}

QStringList ProfileSockets::sync(const QStringList &users)
{
    if (!m_compositor)
        return {};
    for (auto it = m_paths.begin(); it != m_paths.end();) {
        if (users.contains(it.key())) {
            ++it;
            continue;
        }
        ::unlink(QFile::encodeName(it.value()).constData());
        qInfo("ruya-compositor: socket of %s removed", qPrintable(it.key()));
        it = m_paths.erase(it);
    }
    for (const QString &user : users) {
        if (!plainName(user))
            continue;
        if (m_paths.contains(user)) {
            struct stat st;
            const QByteArray path = QFile::encodeName(m_paths.value(user));
            if (::lstat(path.constData(), &st) == 0 && S_ISSOCK(st.st_mode))
                continue;
            m_paths.remove(user);       // gone from the disk: make a new one
        }
        open(user);
    }
    QStringList out = m_paths.keys();
    out.sort();
    return out;
}

bool ProfileSockets::open(const QString &user)
{
    const QByteArray name = user.toLocal8Bit();
    const struct passwd *pw = ::getpwnam(name.constData());
    if (!pw) {
        qWarning("ruya-compositor: no Unix user %s, so no socket for it", name.constData());
        return false;
    }
    const uid_t uid = pw->pw_uid;
    if (uid == 0 || uid == ::getuid()) {
        qWarning("ruya-compositor: %s is root or the shell itself: no socket", name.constData());
        return false;
    }
    const QByteArray dir = QFile::encodeName(m_directory);
    const QByteArray staging = dir + "/.staging";
    const QByteArray tmp = staging + '/' + name;
    const QByteArray path = dir + '/' + name;

    // The staging directory is private (0700, ours): nobody else can reach a socket in it.
    if (::mkdir(staging.constData(), 0700) != 0 && errno != EEXIST) {
        qWarning("ruya-compositor: cannot make %s: %s", staging.constData(), std::strerror(errno));
        return false;
    }
    struct stat st;
    if (::lstat(staging.constData(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ::getuid()
        || (st.st_mode & 077) != 0) {
        qWarning("ruya-compositor: %s is not a private directory of the shell", staging.constData());
        return false;
    }
    struct sockaddr_un addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (static_cast<size_t>(tmp.size()) >= sizeof(addr.sun_path)) {
        qWarning("ruya-compositor: socket path too long: %s", tmp.constData());
        return false;
    }
    std::memcpy(addr.sun_path, tmp.constData(), static_cast<size_t>(tmp.size()));
    ::unlink(tmp.constData());

    const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        qWarning("ruya-compositor: socket(): %s", std::strerror(errno));
        return false;
    }
    const char *step = nullptr;
    if (::bind(fd, reinterpret_cast<const struct sockaddr *>(&addr), sizeof(addr)) != 0)
        step = "bind";
    else if (::listen(fd, 128) != 0)
        step = "listen";
    else if (::chmod(tmp.constData(), 0600) != 0)
        step = "chmod";
    else if (!setUserAcl(tmp.constData(), uid))
        step = "acl";
    else if (::rename(tmp.constData(), path.constData()) != 0)
        step = "rename";
    if (step) {
        const int err = errno;
        ::close(fd);
        ::unlink(tmp.constData());
        qWarning("ruya-compositor: socket for %s failed at %s: %s", name.constData(), step, std::strerror(err));
        return false;
    }
    m_compositor->addSocketDescriptor(fd);      // libwayland owns the fd from here
    m_paths.insert(user, QFile::decodeName(path));
    qInfo("ruya-compositor: socket %s for %s (uid %u): mode 0600, acl user:%s:rw-", path.constData(),
          name.constData(), static_cast<unsigned>(uid), name.constData());
    return true;
}
