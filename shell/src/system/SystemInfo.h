#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QVariantList>

// Read-only facts about the running build, for the Settings "About" pane.
class SystemInfo : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString qtVersion READ qtVersion CONSTANT)
    // The image's Windows runners (ADR-038, RUY-34): the wine and proton lines of the list the image
    // build writes, /usr/lib/ruyaos/play/runners.list (`ruya-pack runner-check --record`, from the one
    // runner.json parser), in its order. One map per runner: name, family, kind, version, licence,
    // sourceUrl. With the mock services (tests, Windows) a sample list of the pinned GE-Proton, read
    // by the same parser. Empty when the file is missing or holds no Windows runner.
    Q_PROPERTY(QVariantList windowsRunners READ windowsRunners CONSTANT)

public:
    // The factory QML uses (the class is not default-constructible, so QML takes it).
    static SystemInfo *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    // The Qt the shell is running on (runtime, not build-time).
    QString qtVersion() const;

    QVariantList windowsRunners() const { return m_windowsRunners; }

    // The Windows runners of a runners.list text: lines of six tab-separated fields (name, family,
    // kind, version, licence, source URL; the last two may be empty) whose kind is "wine" or
    // "proton" and whose version is not empty. Any other line is skipped. Invokable for the tests.
    Q_INVOKABLE QVariantList windowsRunnersIn(const QString &list) const;

private:
    explicit SystemInfo(const QString &runnerList);

    QVariantList m_windowsRunners;
};
