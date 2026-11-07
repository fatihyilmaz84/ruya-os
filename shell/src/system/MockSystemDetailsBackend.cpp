#include "MockSystemDetailsBackend.h"

#include <QTimer>

namespace {
constexpr quint64 GiB = 1024ull * 1024 * 1024;
constexpr quint64 MiB = 1024ull * 1024;

QVariantMap drive(const char *model, const char *type, quint64 bytes, const char *health = nullptr)
{
    QVariantMap d{{QStringLiteral("model"), QString::fromLatin1(model)},
                  {QStringLiteral("type"), QString::fromLatin1(type)},
                  {QStringLiteral("size_bytes"), QVariant::fromValue<quint64>(bytes)}};
    if (health)
        d.insert(QStringLiteral("health"), QString::fromLatin1(health));
    return d;
}

void text(QVariantMap &m, const char *key, const char *value)
{
    m.insert(QString::fromLatin1(key), QString::fromLatin1(value));
}

void number(QVariantMap &m, const char *key, quint64 value)
{
    m.insert(QString::fromLatin1(key), QVariant::fromValue<quint64>(value));
}

// What every machine of the mock shares.
QVariantMap base()
{
    QVariantMap m;
    text(m, "console.name", "RuyaOS");
    text(m, "console.version", "0.0.50");
    text(m, "console.kernel", "6.18.3-200.fc44.x86_64");
    text(m, "console.arch", "x86_64");
    text(m, "console.deployment", "9f3a1c7be2d4");
    text(m, "console.installed", "2025-11");
    text(m, "console.firmware", "uefi");
    number(m, "console.uptime_s", 93784);
    return m;
}

QVariantMap dell()
{
    QVariantMap m = base();
    m.insert(QStringLiteral("console.secure_boot"), false);
    text(m, "console.vendor", "Dell Inc.");
    text(m, "console.model", "OptiPlex 3080");
    text(m, "cpu.model", "Intel(R) Core(TM) i5-10500T CPU @ 2.30GHz");
    number(m, "cpu.cores", 6);
    number(m, "cpu.threads", 12);
    number(m, "cpu.freq_mhz", 2300);
    number(m, "cpu.freq_max_mhz", 3800);
    number(m, "memory.total_bytes", 7970348ull * 1024);
    number(m, "memory.available_bytes", 5214420ull * 1024);
    number(m, "memory.used_bytes", (7970348ull - 5214420ull) * 1024);
    number(m, "memory.swap_total_bytes", 7970344ull * 1024);
    number(m, "memory.swap_used_bytes", 0);
    number(m, "memory.zram_bytes", 7970349056ull);
    text(m, "graphics.vendor", "Intel");
    text(m, "graphics.model", "UHD Graphics 630");
    text(m, "graphics.pci_id", "8086:9bc8");
    text(m, "graphics.driver", "i915");
    text(m, "graphics.driver_version", "6.18.3-200.fc44.x86_64");
    text(m, "graphics.mesa_version", "25.2.6");
    text(m, "graphics.connector", "HDMI-A-1");
    text(m, "graphics.preferred_mode", "1920x1080");
    m.insert(QStringLiteral("storage.drives"),
             QVariantList{drive("Samsung SSD 870", "ssd", 500107862016ull)});
    text(m, "network.interface", "eno1");
    text(m, "network.mac", "c8:4b:d6:aa:bb:cc");
    number(m, "network.link_mbps", 1000);
    text(m, "bluetooth.chipset", "Intel Corp. Bluetooth wireless interface");
    text(m, "bluetooth.usb_id", "8087:0a2b");
    text(m, "bluetooth.address", "9C:B6:D0:12:34:56");
    return m;
}

QVariantMap amd()
{
    QVariantMap m = base();
    m.insert(QStringLiteral("console.secure_boot"), true);
    text(m, "console.vendor", "Minisforum");
    text(m, "console.model", "UM560");
    text(m, "cpu.model", "AMD Ryzen 5 5625U with Radeon Graphics");
    number(m, "cpu.cores", 6);
    number(m, "cpu.threads", 12);
    number(m, "cpu.freq_mhz", 1800);
    number(m, "cpu.freq_max_mhz", 4300);
    number(m, "memory.total_bytes", 15 * GiB + 600 * MiB);
    number(m, "memory.available_bytes", 11 * GiB);
    number(m, "memory.used_bytes", 4 * GiB + 600 * MiB);
    number(m, "memory.swap_total_bytes", 8 * GiB);
    number(m, "memory.swap_used_bytes", 120 * MiB);
    number(m, "memory.zram_bytes", 8 * GiB);
    text(m, "graphics.vendor", "AMD");
    text(m, "graphics.model", "Radeon Graphics (Barcelo)");
    text(m, "graphics.pci_id", "1002:15e7");
    text(m, "graphics.driver", "amdgpu");
    text(m, "graphics.driver_version", "6.18.3-200.fc44.x86_64");
    text(m, "graphics.mesa_version", "25.2.6");
    text(m, "graphics.connector", "HDMI-A-1");
    text(m, "graphics.preferred_mode", "3840x2160");
    m.insert(QStringLiteral("storage.drives"),
             QVariantList{drive("KINGSTON OM8PDP3512B-A01", "nvme", 512110190592ull, "ok")});
    // Wi-Fi only: no wired link speed.
    text(m, "network.interface", "wlp2s0");
    text(m, "network.mac", "7c:b2:7d:11:22:33");
    text(m, "bluetooth.chipset", "Realtek Bluetooth Radio");
    text(m, "bluetooth.address", "7C:B2:7D:11:22:34");
    return m;
}

QVariantMap nvidia()
{
    QVariantMap m = base();
    m.insert(QStringLiteral("console.secure_boot"), false);
    text(m, "console.vendor", "ASRock");
    text(m, "console.model", "B550M Pro4");
    text(m, "cpu.model", "AMD Ryzen 7 5800X 8-Core Processor");
    number(m, "cpu.cores", 8);
    number(m, "cpu.threads", 16);
    number(m, "cpu.freq_mhz", 3800);
    number(m, "cpu.freq_max_mhz", 4850);
    number(m, "memory.total_bytes", 31 * GiB + 400 * MiB);
    number(m, "memory.available_bytes", 24 * GiB);
    number(m, "memory.used_bytes", 7 * GiB + 400 * MiB);
    // No swap at all: absent, not "0 bytes".
    text(m, "graphics.vendor", "NVIDIA");
    text(m, "graphics.model", "GeForce RTX 3070");
    text(m, "graphics.pci_id", "10de:2484");
    text(m, "graphics.driver", "nvidia");
    text(m, "graphics.driver_version", "550.54.14");
    text(m, "graphics.nvidia_version", "550.54.14");
    text(m, "graphics.connector", "DP-1");
    text(m, "graphics.preferred_mode", "2560x1440");
    m.insert(QStringLiteral("storage.drives"),
             QVariantList{drive("WD_BLACK SN770 1TB", "nvme", 1000204886016ull, "ok"),
                          drive("ST2000DM008-2FR102", "hdd", 2000398934016ull)});
    text(m, "network.interface", "enp5s0");
    text(m, "network.mac", "d8:5e:d3:44:55:66");
    number(m, "network.link_mbps", 2500);
    return m;
}

QVariantMap profileMap(const QString &name)
{
    if (name == QLatin1String("amd"))
        return amd();
    if (name == QLatin1String("nvidia"))
        return nvidia();
    return dell();
}
} // namespace

MockSystemDetailsBackend::MockSystemDetailsBackend(QObject *parent)
    : SystemDetailsBackend(parent)
    , m_profile(QStringLiteral("dell"))
    , m_info(dell())
{
}

QStringList MockSystemDetailsBackend::profiles()
{
    return {QStringLiteral("dell"), QStringLiteral("amd"), QStringLiteral("nvidia")};
}

void MockSystemDetailsBackend::refresh()
{
    const quint64 request = beginRequest();
    if (m_delay <= 0) {
        deliver(request, m_info);
        return;
    }
    ++m_pending;
    QTimer::singleShot(m_delay, this, [this, request, snapshot = m_info] {
        --m_pending;
        deliver(request, snapshot);
    });
}

void MockSystemDetailsBackend::publish()
{
    deliver(beginRequest(), m_info);
}

void MockSystemDetailsBackend::setProfile(const QString &name)
{
    m_profile = profiles().contains(name) ? name : QStringLiteral("dell");
    m_info = profileMap(m_profile);
    publish();
}

void MockSystemDetailsBackend::setValue(const QString &key, const QVariant &value)
{
    m_info.insert(key, value);
    publish();
}

void MockSystemDetailsBackend::removeValue(const QString &key)
{
    m_info.remove(key);
    publish();
}
