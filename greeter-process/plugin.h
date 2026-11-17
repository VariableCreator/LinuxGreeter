/****************************************************************************
**
** greeter-process - QML module "GreeterProcess 1.0"
**
****************************************************************************/

#ifndef GREETER_PROCESS_PLUGIN_H
#define GREETER_PROCESS_PLUGIN_H

#include <QQmlExtensionPlugin>

class GreeterProcessPlugin : public QQmlExtensionPlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

public:
    void registerTypes(const char *uri) override;
};

#endif // GREETER_PROCESS_PLUGIN_H