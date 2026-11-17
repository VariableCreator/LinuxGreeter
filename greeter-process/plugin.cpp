#include "plugin.h"

#include <QtQml/qqml.h>

#include "process.h"

void GreeterProcessPlugin::registerTypes(const char *uri)
{
    // QML usage:  import GreeterProcess 1.0
    qmlRegisterType<Process>(uri, 1, 0, "Process");
}