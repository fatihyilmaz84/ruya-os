#include "IdleInhibitManager.h"

#include <QPointer>

// One idle-inhibitor object of one client. It lives as long as the client's resource: the object is
// deleted when the client destroys it or goes away.
class IdleInhibitManager::Inhibitor : public QtWaylandServer::zwp_idle_inhibitor_v1
{
public:
    Inhibitor(IdleInhibitManager *owner, struct ::wl_client *client, int id, int version, int number)
        : QtWaylandServer::zwp_idle_inhibitor_v1(client, id, version)
        , m_owner(owner)
        , m_number(number)
    {
        emit m_owner->inhibitorAdded(m_number);
    }

protected:
    void zwp_idle_inhibitor_v1_destroy(Resource *resource) override { wl_resource_destroy(resource->handle); }
    void zwp_idle_inhibitor_v1_destroy_resource(Resource *) override
    {
        if (m_owner)
            emit m_owner->inhibitorRemoved(m_number);
        delete this;
    }

private:
    // The manager can be gone before the client's resources are (the compositor shuts down).
    QPointer<IdleInhibitManager> m_owner;
    int m_number;
};

IdleInhibitManager::IdleInhibitManager(QObject *parent)
    : QWaylandCompositorExtensionTemplate<IdleInhibitManager>(parent)
{
}

void IdleInhibitManager::initialize()
{
    QWaylandCompositorExtensionTemplate::initialize();
    auto *compositor = static_cast<QWaylandCompositor *>(extensionContainer());
    if (!compositor) {
        qWarning("ruya-compositor: IdleInhibitManager has no compositor to extend");
        return;
    }
    init(compositor->display(), 1);
}

void IdleInhibitManager::zwp_idle_inhibit_manager_v1_destroy(Resource *resource)
{
    wl_resource_destroy(resource->handle);
}

void IdleInhibitManager::zwp_idle_inhibit_manager_v1_create_inhibitor(Resource *resource, uint32_t id,
                                                                      struct ::wl_resource *surface)
{
    Q_UNUSED(surface) // the inhibitor counts while it exists; the app destroys it when it stops
    new Inhibitor(this, resource->client(), int(id), resource->version(), m_next++);
}
