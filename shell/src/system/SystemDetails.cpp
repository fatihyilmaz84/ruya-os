#include "SystemDetails.h"

#include "DBusSystemDetailsBackend.h"
#include "MockSystemDetailsBackend.h"

#include <QGuiApplication>
#include <QQuickWindow>
#include <QRect>
#include <QSGRendererInterface>
#include <QScreen>
#include <QtGui/qtguiglobal.h>

#if QT_CONFIG(opengl)
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#endif

namespace {
#if QT_CONFIG(opengl)
// The renderer and version strings of the driver, from a context of our own (a context is cheap and
// the scene graph's own belongs to the render thread). Empty when none can be made.
QVariantMap glStrings()
{
    QVariantMap out;
    QOpenGLContext context;
    if (!context.create())
        return out;
    QOffscreenSurface surface;
    surface.setFormat(context.format());
    surface.create();
    if (!surface.isValid() || !context.makeCurrent(&surface))
        return out;
    if (QOpenGLFunctions *f = context.functions()) {
        const auto text = [f](GLenum name) {
            const auto *s = reinterpret_cast<const char *>(f->glGetString(name));
            return s ? QString::fromLatin1(s).simplified() : QString();
        };
        const QString renderer = text(GL_RENDERER);
        const QString version = text(GL_VERSION);
        if (!renderer.isEmpty())
            out.insert(QStringLiteral("graphics.renderer"), renderer);
        if (!version.isEmpty())
            out.insert(QStringLiteral("graphics.gl_version"), version);
    }
    context.doneCurrent();
    return out;
}
#endif

QString apiName(QSGRendererInterface::GraphicsApi api)
{
    switch (api) {
    case QSGRendererInterface::OpenGL: return QStringLiteral("OpenGL");
    case QSGRendererInterface::Vulkan: return QStringLiteral("Vulkan");
    case QSGRendererInterface::Direct3D11: return QStringLiteral("Direct3D 11");
    case QSGRendererInterface::Direct3D12: return QStringLiteral("Direct3D 12");
    case QSGRendererInterface::Metal: return QStringLiteral("Metal");
    case QSGRendererInterface::Software: return QStringLiteral("Software");
    default: return QString();
    }
}
} // namespace

SystemDetails::SystemDetails(std::unique_ptr<SystemDetailsBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &SystemDetailsBackend::listed, this, &SystemDetails::apply);
    m_backend->refresh();
}

SystemDetails::~SystemDetails() = default;

SystemDetails *SystemDetails::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<SystemDetailsBackend> backend;
    // Like Thermal: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockSystemDetailsBackend>();
    else
        backend = std::make_unique<DBusSystemDetailsBackend>();
    return new SystemDetails(std::move(backend));
}

QVariantMap SystemDetails::info() const
{
    QVariantMap out = m_service;
    // What this session knows is added; the service never sends these keys.
    for (auto it = m_local.cbegin(); it != m_local.cend(); ++it)
        out.insert(it.key(), it.value());
    return out;
}

void SystemDetails::setLiveIntervalMs(int ms)
{
    ms = qMax(10, ms);
    if (ms == m_liveIntervalMs)
        return;
    m_liveIntervalMs = ms;
    emit liveIntervalMsChanged();
}

void SystemDetails::refresh()
{
    ++m_refreshCount;
    emit refreshCountChanged();
    m_backend->refresh();
}

void SystemDetails::apply(const QVariantMap &info)
{
    const bool first = !m_valid;
    if (!first && info == m_service)
        return;
    m_service = info;
    m_valid = true;
    emit infoChanged();
}

void SystemDetails::probeLocal(QQuickWindow *window)
{
    if (m_backend->isMock())
        return;
    QVariantMap local;
    QScreen *screen = window ? window->screen() : QGuiApplication::primaryScreen();
    if (screen) {
        const qreal ratio = screen->devicePixelRatio();
        local.insert(QStringLiteral("display.name"), screen->name());
        local.insert(QStringLiteral("display.width"), qRound(screen->geometry().width() * ratio));
        local.insert(QStringLiteral("display.height"), qRound(screen->geometry().height() * ratio));
        if (screen->refreshRate() > 0)
            local.insert(QStringLiteral("display.refresh_hz"), screen->refreshRate());
    }
    QSGRendererInterface::GraphicsApi api = QSGRendererInterface::Unknown;
    if (window && window->rendererInterface())
        api = window->rendererInterface()->graphicsApi();
    const QString name = apiName(api);
    if (!name.isEmpty())
        local.insert(QStringLiteral("graphics.api"), name);
#if QT_CONFIG(opengl)
    // The software renderer and the offscreen platform (tests) have no driver to ask.
    if (api == QSGRendererInterface::OpenGL && QGuiApplication::platformName() != QLatin1String("offscreen")) {
        const QVariantMap gl = glStrings();
        for (auto it = gl.cbegin(); it != gl.cend(); ++it)
            local.insert(it.key(), it.value());
    }
#endif
    if (local == m_local)
        return;
    m_local = local;
    emit infoChanged();
}

QStringList SystemDetails::mockProfiles() const
{
    return MockSystemDetailsBackend::profiles();
}

void SystemDetails::mockProfile(const QString &name)
{
    if (auto *mock = qobject_cast<MockSystemDetailsBackend *>(m_backend.get()))
        mock->setProfile(name);
}

void SystemDetails::mockSet(const QString &key, const QVariant &value)
{
    if (auto *mock = qobject_cast<MockSystemDetailsBackend *>(m_backend.get()))
        mock->setValue(key, value);
}

void SystemDetails::mockRemove(const QString &key)
{
    if (auto *mock = qobject_cast<MockSystemDetailsBackend *>(m_backend.get()))
        mock->removeValue(key);
}

void SystemDetails::mockReset()
{
    mockProfile(QStringLiteral("dell"));
    setLiveIntervalMs(DefaultLiveIntervalMs);
}

void SystemDetails::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockSystemDetailsBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        mock->refresh();
        mock->setReplyDelay(0);
    }
}

int SystemDetails::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockSystemDetailsBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
