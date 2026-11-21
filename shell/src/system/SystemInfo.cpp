#include "SystemInfo.h"

#include <QFile>
#include <QStringList>
#include <QVariantMap>
#include <QtGlobal>

// Written by the image build (image/play/install-runners.sh, docs/specs/05-play-packages.md 6.4).
static const char RunnerListPath[] = "/usr/lib/ruyaos/play/runners.list";

// What the mock services show: the runners image/play/runners/ pins (ProtonGE11, Wine11), as the build
// records them (folder name order).
static const char MockRunnerList[] =
    "ProtonGE11\tproton-ge\tproton\tGE-Proton11-12\t"
    "BSD-3-Clause AND LGPL-2.1-or-later AND LGPL-2.0-or-later AND Zlib AND MIT AND OFL-1.1\t"
    "https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton11-12\n"
    "Wine11\twine\twine\twine-11.0\t"
    "LGPL-2.1-or-later AND LGPL-2.1-only AND BSD-3-Clause AND BSD-2-Clause AND NCSA AND MIT AND Zlib AND IJG "
    "AND libpng-2.0 AND libtiff AND OLDAP-2.8 AND TU-Berlin-1.0 AND WTFPL\t"
    "https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz\n";

SystemInfo *SystemInfo::create(QQmlEngine *, QJSEngine *)
{
    // Like the service facades: the real file on Linux unless RUYA_SERVICES=mock, the sample elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    QString list;
    if (mock) {
        list = QString::fromUtf8(MockRunnerList);
    } else {
        QFile file(QString::fromLatin1(RunnerListPath));
        if (file.open(QIODevice::ReadOnly))
            list = QString::fromUtf8(file.read(64 * 1024));
    }
    return new SystemInfo(list);
}

SystemInfo::SystemInfo(const QString &runnerList)
    : m_windowsRunners(windowsRunnersIn(runnerList))
{
}

QString SystemInfo::qtVersion() const
{
    return QString::fromLatin1(qVersion());
}

QVariantList SystemInfo::windowsRunnersIn(const QString &list) const
{
    QVariantList out;
    const QStringList lines = list.split(QLatin1Char('\n'));
    for (const QString &line : lines) {
        const QStringList f = line.split(QLatin1Char('\t'));
        if (f.size() != 6 || f.at(3).isEmpty())
            continue;
        if (f.at(2) != QLatin1String("wine") && f.at(2) != QLatin1String("proton"))
            continue;
        out.append(QVariantMap{
            {QStringLiteral("name"), f.at(0)},
            {QStringLiteral("family"), f.at(1)},
            {QStringLiteral("kind"), f.at(2)},
            {QStringLiteral("version"), f.at(3)},
            {QStringLiteral("licence"), f.at(4)},
            {QStringLiteral("sourceUrl"), f.at(5)},
        });
    }
    return out;
}
