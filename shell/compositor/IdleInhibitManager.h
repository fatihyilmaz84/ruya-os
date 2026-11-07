#pragma once

#include <QtQml/qqml.h>
#include <QtQml/QQmlParserStatus>
#include <QtWaylandCompositor/QWaylandCompositor>
#include <QtWaylandCompositor/QWaylandCompositorExtensionTemplate>

#include "qwayland-server-idle-inhibit-unstable-v1.h"

// The Wayland protocol zwp_idle_inhibit_manager_v1 (T-202): video players and games ask the
// compositor not to blank the screen while they run. QtWaylandCompositor has no such extension, so
// this is one, written after Qt's own custom-extension example (qtwayland examples/wayland/
// custom-extension: a QWaylandCompositorExtensionTemplate that also derives from the generated
// QtWaylandServer class, a constructor taking the compositor, an initialize() that calls init()).
// The protocol file is idle-inhibit-unstable-v1.xml next to this header; qtwaylandscanner writes
// the server glue from it at build time. The class keeps no state about idling: it tells QML when
// an inhibitor appears and goes away (with its client, or when the app destroys it), and
// Compositor.qml hands that to the shell's IdleInhibit singleton.
//
// Declared from QML, the extension is built with the default constructor and is not initialised by
// Qt (only the C++ constructor with a container posts the event that does it): as the Qt Quick
// extension wrappers do, it is a QQmlParserStatus and initialises itself in componentComplete().
class IdleInhibitManager : public QWaylandCompositorExtensionTemplate<IdleInhibitManager>,
                           public QtWaylandServer::zwp_idle_inhibit_manager_v1,
                           public QQmlParserStatus
{
    Q_OBJECT
    Q_INTERFACES(QQmlParserStatus)
    QML_NAMED_ELEMENT(IdleInhibitManager)

public:
    explicit IdleInhibitManager(QWaylandCompositor *compositor = nullptr);

    void initialize() override;

    void classBegin() override {}
    void componentComplete() override;

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
