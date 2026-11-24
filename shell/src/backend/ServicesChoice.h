#pragma once

#include <QString>
#include <QtGlobal>

namespace ruya {

// Which transport a facade's create() uses, read from RUYA_SERVICES=mock|dbus. On Linux the
// default is D-Bus (the services exist there), so only "mock" selects the mock; elsewhere the
// default is the mock, so only "dbus" selects D-Bus. Every facade asks here instead of repeating
// the rule; read the variable at the call (tests and main.cpp set it before the singleton is made).
inline bool useMockServices()
{
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    return choice == QLatin1String("mock");
#else
    return choice != QLatin1String("dbus");
#endif
}

} // namespace ruya
