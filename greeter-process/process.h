/****************************************************************************
**
** greeter-process
**
** Thin QML wrapper around QProcess so that an SDDM theme can start external
** applications (e.g. the oidc-login web browser used for the "HM Anmeldung").
**
****************************************************************************/

#ifndef PROCESS_H
#define PROCESS_H

#include <QObject>
#include <QProcess>
#include <QStringList>

class Process : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString program READ program WRITE setProgram NOTIFY programChanged)
    Q_PROPERTY(QStringList arguments READ arguments WRITE setArguments NOTIFY argumentsChanged)
    Q_PROPERTY(QString workingDirectory READ workingDirectory WRITE setWorkingDirectory NOTIFY workingDirectoryChanged)
    Q_PROPERTY(bool running READ isRunning NOTIFY runningChanged)
    Q_PROPERTY(QString output READ output NOTIFY outputChanged)

public:
    explicit Process(QObject *parent = nullptr);
    ~Process() override = default;

    QString program() const;
    void setProgram(const QString &program);

    QStringList arguments() const;
    void setArguments(const QStringList &arguments);

    QString workingDirectory() const;
    void setWorkingDirectory(const QString &workingDirectory);

    bool isRunning() const;

    // Collected standard output of the child process (for OIDC_ACCOUNT parsing).
    QString output() const;

public slots:
    // Starts the program as a child of the greeter (non-detached) so the theme
    // receives started()/finished()/errorOccurred(). Returns false if the
    // program property is empty or a program is already running.
    bool start();

    // Asks the running program to terminate (SIGTERM).
    void terminate();

    // Kills the running program (SIGKILL).
    void kill();

    // Discards the collected standard output. Used by the theme once
    // the output has been evaluated, so that e.g. a password (OIDC_AUTOLOGIN)
    // does not stay in greeter memory until the next start.
    void clearOutput();

signals:
    void programChanged();
    void argumentsChanged();
    void workingDirectoryChanged();
    void runningChanged();
    void outputChanged();

    void started();
    void finished(int exitCode);
    void errorOccurred(const QString &error);

private:
    QProcess *m_process;
    QString m_program;
    QStringList m_arguments;
    QString m_workingDirectory;
    QString m_output;
};

#endif // PROCESS_H