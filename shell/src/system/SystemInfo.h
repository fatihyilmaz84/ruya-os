#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>

// Read-only facts about the running build, for the Settings "About" pane.
class SystemInfo : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString qtVersion READ qtVersion CONSTANT)

public:
    using QObject::QObject;

    static SystemInfo *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    // The Qt the shell is running on (runtime, not build-time).
    QString qtVersion() const;
};
