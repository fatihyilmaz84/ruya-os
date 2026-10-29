#pragma once

#include "StoreBackend.h"

#include <QHash>
#include <QSet>
#include <QTimer>

// In-memory store: a catalogue of 12 apps (all sources and controller levels), three installed
// from the start, one of them with an update. An install runs download (0-49) then install
// (50-100) in 20 steps of about 100 ms (10 ms with RUYA_MOCK_FAST=1), then reports
// InstalledChanged and ok. "org.example.Broken" always fails part-way.
class MockStoreBackend final : public StoreBackend
{
    Q_OBJECT

public:
    explicit MockStoreBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void search(const QString &query, bool gamepadOnly, uint limit) override;
    void install(const QString &id) override;
    void uninstall(const QString &id, bool deleteData) override;
    void update(const QString &id) override;

    // Tests only: whether an uninstall of this app asked for its data to be deleted.
    bool dataDeleted(const QString &id) const { return m_dataDeleted.contains(id); }
    void reset();
    int searchCount() const { return m_searchCount; }
    void announceCatalogChanged() { emit catalogChanged(); }

private:
    struct Job
    {
        QString id;
        enum Kind { Install, Update, Uninstall } kind = Install;
        int percent = 0;
    };

    void initState();
    int indexOf(const QString &id) const;
    void startJob(const QString &id, Job::Kind kind);
    void step();
    void finish(const Job &job, const QString &status);
    void reject(const QString &id, const QString &status);
    QList<AppInfo> installedApps() const;

    QList<AppInfo> m_apps;
    QList<Job> m_jobs; // one transaction queue: only the first runs
    QSet<QString> m_dataDeleted;
    QTimer m_timer;
    int m_stepMs = 100;
    int m_searchCount = 0;
};
