#include "process.h"

#include <QProcessEnvironment>

Process::Process(QObject *parent)
    : QObject(parent)
    , m_process(new QProcess(this))
{
    connect(m_process, &QProcess::started, this, &Process::started);

    connect(m_process, &QProcess::stateChanged, this, [this](QProcess::ProcessState) {
        emit runningChanged();
    });

    connect(m_process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int exitCode, QProcess::ExitStatus exitStatus) {
                Q_UNUSED(exitStatus);
                emit runningChanged();
                emit finished(exitCode);
            });

    connect(m_process, &QProcess::errorOccurred,
            this, [this](QProcess::ProcessError processError) {
                Q_UNUSED(processError);
                emit runningChanged();
                emit errorOccurred(m_process->errorString());
            });

    // Collect the child process standard output
    // void QProcess::readyReadStandardOutput() This signal is emitted when the process has made new data available through its standard output channel.
    connect(m_process, &QProcess::readyReadStandardOutput, this, [this]() {
        const QByteArray chunk = m_process->readAllStandardOutput();
        if (chunk.isEmpty())
            return;
        m_output += QString::fromUtf8(chunk);
        emit outputChanged();
    });
}

QString Process::program() const
{
    return m_program;
}

void Process::setProgram(const QString &program)
{
    if (m_program == program)
        return;
    m_program = program;
    emit programChanged();
}

QStringList Process::arguments() const
{
    return m_arguments;
}

void Process::setArguments(const QStringList &arguments)
{
    if (m_arguments == arguments)
        return;
    m_arguments = arguments;
    emit argumentsChanged();
}

QString Process::workingDirectory() const
{
    return m_workingDirectory;
}

void Process::setWorkingDirectory(const QString &workingDirectory)
{
    if (m_workingDirectory == workingDirectory)
        return;
    m_workingDirectory = workingDirectory;
    emit workingDirectoryChanged();
}

bool Process::isRunning() const
{
    return m_process->state() != QProcess::NotRunning;
}

QString Process::output() const
{
    return m_output;
}

bool Process::start()
{
    if (m_program.isEmpty()) {
        emit errorOccurred(tr("No program specified."));
        return false;
    }

    if (isRunning())
        return false;

    // Start fresh on every launch
    m_output.clear();
    emit outputChanged();

    if (!m_workingDirectory.isEmpty())
        m_process->setWorkingDirectory(m_workingDirectory);

    // The Chromium/QtWebEngine sandbox does not run in the SDDM greeter context (user sddm,
    // no user namespace/chrome-sandbox): the zygote dies with SIGTRAP
    // (exit code 5 in the theme). So the sandbox flags are set for the child
    // process - fixed value on purpose: an ambient QTWEBENGINE_CHROMIUM_FLAGS
    // is deliberately overwritten (the theme passes no browser flags).
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("QTWEBENGINE_CHROMIUM_FLAGS"),
               QStringLiteral("--no-sandbox --disable-dev-shm-usage"));
    m_process->setProcessEnvironment(env);

    m_process->start(m_program, m_arguments);
    return true;
}

void Process::terminate()
{
    if (isRunning())
        m_process->terminate();
}

void Process::kill()
{
    if (isRunning())
        m_process->kill();
}

void Process::clearOutput()
{
    if (m_output.isEmpty())
        return;
    m_output.clear();
    emit outputChanged();
}