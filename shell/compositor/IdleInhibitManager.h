#pragma once

#include <QtQml/qqml.h>
#include <QtWaylandCompositor/QWaylandCompositor>
#include <QtWaylandCompositor/QWaylandCompositorExtensionTemplate>

#include "qwayland-server-idle-inhibit-unstable-v1.h"

// The Wayland protocol zwp_idle_inhibit_manager_v1 (T-202): video players and games ask the
// compositor not to blank the screen while they run. QtWaylandCompositor has no such extension, so
// this is one (the protocol file is idle-inhibit-unstable-v1.xml next to this header; the server
// glue is generated from it by qtwaylandscanner at build time). It keeps no state of its own about
// idling: it tells QML when an inhibitor appears and goes away (with its client, or when the app
// destroys it), and Compositor.qml hands that to the shell's IdleInhibit singleton.
class IdleInhibitManager : public QWaylandCompositorExtensionTemplate<IdleInhibitManager>,
                           public QtWaylandServer::zwp_idle_inhibit_manager_v1
{
    Q_OBJECT
    QML_NAMED_ELEMENT(IdleInhibitManager)

public:
    explicit IdleInhibitManager(QObject *parent = nullptr);

    void initialize() override;

signals:
    // `id` is unique for the life of the process: the shell holds the reason "wayland:<id>".
    void inhibitorAdded(int id);
    void inhibitorRemoved(int id);

protected:
    void zwp_idle_inhibit_manager_v1_destroy(Resource *resource) override;
    void zwp_idle_inhibit_manager_v1_create_inhibitor(Resource *resource, uint32_t id, struct ::wl_resource *surface) override;

private:
    class Inhibitor;
    int m_next = 1;
};
