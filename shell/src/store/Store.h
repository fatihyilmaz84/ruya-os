#pragma once

#include "StoreBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Store1: the catalogue, the installed apps and the running jobs.
// Backend: RUYA_SERVICES=mock|dbus. Unlike Profiles this defaults to the mock on every OS,
// because the D-Bus service (ruya-store, blocker B-004) does not exist yet; flip the default to
// follow Profiles once it does.
//
// App records are plain objects: { id, name, summary, description, developer, source,
// controller, ageRating, permissions, installedSize, icon, tile, hero, installed,
// updateAvailable }.
class Store : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The whole catalogue (search("")), with the installed flags kept current.
    Q_PROPERTY(QVariantList catalogue READ catalogue NOTIFY catalogueChanged)
    Q_PROPERTY(QVariantList installed READ installed NOTIFY installedChanged)
    // Result of the last search(); search("") also fills the catalogue.
    Q_PROPERTY(QVariantList results READ results NOTIFY resultsChanged)
    // App id -> { percent, phase } for every job that has reported progress and not finished.
    Q_PROPERTY(QVariantMap jobs READ jobs NOTIFY jobsChanged)
    // True once the service has answered (always, for the mock).
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Store(std::unique_ptr<StoreBackend> backend, QObject *parent = nullptr);
    ~Store() override;

    static Store *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList catalogue() const { return m_catalogue; }
    QVariantList installed() const { return m_installed; }
    QVariantList results() const { return m_results; }
    QVariantMap jobs() const { return m_jobs; }
    bool isAvailable() const { return m_available; }
    bool isMock() const { return m_backend->isMock(); }

    // Results arrive with searchFinished / results.
    Q_INVOKABLE void search(const QString &query);
    // Results arrive with jobFinished. A refused request (unknown id, busy, ...) finishes with
    // its status and no progress.
    Q_INVOKABLE void install(const QString &appId);
    Q_INVOKABLE void uninstall(const QString &appId, bool deleteData);
    Q_INVOKABLE void update(const QString &appId);
    // The record of an app from the catalogue, or an empty object.
    Q_INVOKABLE QVariantMap app(const QString &appId) const;

    // Tests only, and only with the mock backend (otherwise false / no-op).
    Q_INVOKABLE bool mockDataDeleted(const QString &appId) const;
    Q_INVOKABLE void mockReset();

signals:
    void catalogueChanged();
    void installedChanged();
    void resultsChanged();
    void jobsChanged();
    void availableChanged();
    void searchFinished(const QString &query, const QVariantList &apps);
    // status: see api/dbus/org.ruyaos.Store1.xml (JobFinished statuses, plus request statuses).
    void jobFinished(const QString &appId, const QString &status);

private:
    static QVariantList toList(const QList<AppInfo> &apps);

    std::unique_ptr<StoreBackend> m_backend;
    QVariantList m_catalogue;
    QVariantList m_installed;
    QVariantList m_results;
    QVariantMap m_jobs;
    bool m_available = false;
};
