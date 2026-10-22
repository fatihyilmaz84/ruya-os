#include "SystemInfo.h"

#include <QtGlobal>

SystemInfo *SystemInfo::create(QQmlEngine *, QJSEngine *)
{
    return new SystemInfo;
}

QString SystemInfo::qtVersion() const
{
    return QString::fromLatin1(qVersion());
}
