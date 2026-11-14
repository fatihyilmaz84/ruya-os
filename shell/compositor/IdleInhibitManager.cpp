#include "IdleInhibitManager.h"

#include <QPointer>

// One idle-inhibitor object of one client. It lives as long as the client's resource: the object is
// deleted when the client destroys it or goes away.
class IdleInhibitManager::Inhibitor : public QtWaylandServer::zwp_idle_inhibitor_v1
{
public:
    Inhibitor(IdleInhibitManager *owner, struct ::wl_client *client, int id, int version, int number,
              QWaylandSurface *surface)
        : QtWaylandServer::zwp_idle_inhibitor_v1(client, id, version)
        , m_owner(owner)
        , m_number(number)
    {
        emit m_owner->inhibitorAdded(m_number, surface);
        // The surface can die before the inhibitor: it stops counting then (RUY-561).
        if (surface)
            m_surfaceGone = QObject::connect(surface, &QObject::destroyed, owner, [this]() { reportRemoved(); });
    }

protected:
    void zwp_idle_inhibitor_v1_destroy(Resource *resource) override { wl_resource_destroy(resource->handle); }
    void zwp_idle_inhibitor_v1_destroy_resource(Resource *) override
    {
        QObject::disconnect(m_surfaceGone); // the lambda points at this object
        reportRemoved();
        delete this;
    }

private:
    void reportRemoved()
    {
        if (m_removed)
            return;
        m_removed = true;
        if (m_owner)
            emit m_owner->inhibitorRemoved(m_number);
    }

    // The manager can be gone before the client's resources are (the compositor shuts down).
    QPointer<IdleInhibitManager> m_owner;
    int m_number;
    bool m_removed = false;
    QMetaObject::Connection m_surfaceGone;
};

IdleInhibitManager::IdleInhibitManager(QWaylandCompositor *compositor)
    : QWaylandCompositorExtensionTemplate<IdleInhibitManager>(compositor)
{
}

void IdleInhibitManager::componentComplete()
{
    if (!isInitialized())
        initialize();
}

void IdleInhibitManager::initialize()
{
    QWaylandCompositorExtensionTemplate::initialize();
    // Declared in QML inside the WaylandCompositor, the container is the compositor (the parent).
    auto *compositor = qobject_cast<QWaylandCompositor *>(extensionContainer());
    if (!compositor)
        compositor = qobject_cast<QWaylandCompositor *>(parent());
    if (!compositor) {
        qWarning("ruya-compositor: IdleInhibitManager has no compositor to extend, idle-inhibit is not advertised");
        return;
    }
    init(compositor->display(), 1);
    // One line for the VM journal: apps can bind the global only if this was reached.
    qInfo("ruya-shell: idle-inhibit manager advertised");
}

void IdleInhibitManager::zwp_idle_inhibit_manager_v1_destroy(Resource *resource)
{
    wl_resource_destroy(resource->handle);
}

void IdleInhibitManager::zwp_idle_inhibit_manager_v1_create_inhibitor(Resource *resource, uint32_t id,
                                                                      struct ::wl_resource *surface)
{
    // Whether it counts is the shell's decision (it follows the surface's app); only the surface is kept.
    new Inhibitor(this, resource->client(), int(id), resource->version(), m_next++,
                  surface ? QWaylandSurface::fromResource(surface) : nullptr);
}
