#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

// One app record of org.ruyaos.Store1 (api/dbus/org.ruyaos.Store1.xml, "App record").
struct AppInfo
{
    QString id;
    QString name;
    QString summary;
    QString description;
    QString developer;
    QString source = QStringLiteral("community"); // "official" | "community" | "developer"
    QString controller = QStringLiteral("none");  // "full" | "partial" | "none"
    QString ageRating = QStringLiteral("all");
    QStringList permissions;
    qulonglong installedSize = 0;
    QString icon;
    QString tile;
    QString hero;
    bool installed = false;
    bool updateAvailable = false;

    // The record as QML sees it (camelCase keys).
    QVariantMap toVariant() const
    {
        return {
            {QStringLiteral("id"), id},
            {QStringLiteral("name"), name},
            {QStringLiteral("summary"), summary},
            {QStringLiteral("description"), description},
            {QStringLiteral("developer"), developer},
            {QStringLiteral("source"), source},
            {QStringLiteral("controller"), controller},
            {QStringLiteral("ageRating"), ageRating},
            {QStringLiteral("permissions"), permissions},
            {QStringLiteral("installedSize"), installedSize},
            {QStringLiteral("icon"), icon},
            {QStringLiteral("tile"), tile},
            {QStringLiteral("hero"), hero},
            {QStringLiteral("installed"), installed},
            {QStringLiteral("updateAvailable"), updateAvailable},
        };
    }
};

// Transport behind the Store QML singleton: org.ruyaos.Store1 over D-Bus, or an in-memory mock.
// Results arrive asynchronously through signals. The backend, not the facade, maps the service's
// job ids to app ids.
class StoreBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0;                           // reports the installed list
    virtual void search(const QString &query) = 0;        // "" = the whole catalogue
    virtual void install(const QString &id) = 0;
    virtual void uninstall(const QString &id, bool deleteData) = 0;
    virtual void update(const QString &id) = 0;

signals:
    void searchFinished(const QString &query, const QList<AppInfo> &apps);
    void installedListed(const QList<AppInfo> &apps);
    // The set of installed apps or an update flag changed: the facade reads both lists again.
    void installedChanged();
    void jobProgress(const QString &appId, int percent, const QString &phase);
    // status: see the XML ("ok", "failed", "network", ...). A request the service refused
    // ("unknown-app", "busy", ...) is reported the same way, without any progress before it.
    void jobFinished(const QString &appId, const QString &status);
};
