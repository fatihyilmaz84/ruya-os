#include "AppGate.h"

#ifdef Q_OS_UNIX
#include <pwd.h>
#include <unistd.h>
#endif

qint64 AppGate::shellUid()
{
#ifdef Q_OS_UNIX
    return static_cast<qint64>(::getuid());
#else
    return -1;
#endif
}

QString AppGate::unixUser(const QString &profileId)
{
    if (profileId.isEmpty() || profileId.size() > 32)
        return QString();
    for (const QChar c : profileId) {
        const bool ok = (c >= QLatin1Char('a') && c <= QLatin1Char('z'))
            || (c >= QLatin1Char('A') && c <= QLatin1Char('Z'))
            || (c >= QLatin1Char('0') && c <= QLatin1Char('9'))
            || c == QLatin1Char('_') || c == QLatin1Char('-');
        if (!ok)
            return QString();
    }
    return QStringLiteral("ruya-") + profileId;
}

qint64 AppGate::uidOf(const QString &user)
{
#ifdef Q_OS_UNIX
    if (user.isEmpty())
        return -1;
    const QByteArray name = user.toLocal8Bit();
    const struct passwd *pw = ::getpwnam(name.constData());
    return pw ? static_cast<qint64>(pw->pw_uid) : -1;
#else
    Q_UNUSED(user)
    return -1;
#endif
}

QVariantMap AppGate::verdict(qint64 clientUid, qint64 shellUid, const QString &activeProfile,
                             qint64 activeUid)
{
    const auto answer = [](bool accepted, const QString &profile, const char *reason) {
        return QVariantMap{
            { QStringLiteral("accepted"), accepted },
            { QStringLiteral("profile"), profile },
            { QStringLiteral("reason"), QString::fromLatin1(reason) },
        };
    };
    if (clientUid >= 0 && clientUid == shellUid)
        return answer(true, QString(), "shell");
    // Never root, nor an unknown uid, whatever the profile table says.
    if (clientUid <= 0)
        return answer(false, QString(), "other-user");
    const bool signedIn = !activeProfile.isEmpty() && activeUid > 0;
    if (signedIn && clientUid == activeUid)
        return answer(true, activeProfile, "profile");
    if (!signedIn)
        return answer(false, QString(), "nobody-signed-in");
    return answer(false, QString(), "other-user");
}
