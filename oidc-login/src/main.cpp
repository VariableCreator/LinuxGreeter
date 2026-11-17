/****************************************************************************
**
** Project Name: OIDC Login
**
** Author: Dirk Henrici
** Contact: dirk.henrici@hm.edu
**
** Description:
** Web browser to log-in via OIDC and call another program with the session-id
**
** License: GPL-3.0-only
** Copyright (c) 2025 Hochschule München
**
****************************************************************************/

#include "mainwindow.h"

#include <QApplication>
#include <QDir>
#include <QLocale>
#include <QLockFile>
#include <QLibraryInfo>
#include <QMessageBox>
#include <QScreen>
#include <QStandardPaths>
#include <QTranslator>

int main(int argc, char *argv[])
{
    // SDDM greeter context (user sddm): the Chromium sandbox (zygote/user namespace)
    // is not available there -> SIGTRAP/code 5. Set before
    // QApplication so WebEngineContext picks it up. Fixed value on purpose: the
    // greeter passes no browser flags, so an ambient QTWEBENGINE_CHROMIUM_FLAGS
    // is deliberately NOT honoured (no launch flags).
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS", "--no-sandbox --disable-dev-shm-usage");
    // "--autologin": after successful account creation additionally emit the captured
    // credentials on stdout so the SDDM greeter
    // can log in directly (see RequestInterceptor::emitAutoLogin).
    // The theme passes this flag when autoLoginAfterHm=true (theme.conf), which
    // install.sh fills from config/oidc-login.conf: AUTO_LOGIN_AFTER_HM.
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--autologin") == 0) {
            qputenv("OIDC_AUTOLOGIN", "1");
            break;
        }
    }
    QApplication a(argc, argv);

    // Load Qt base translations (e.g. for button texts of standard dialogs)
    QTranslator qtTranslator;
    if (qtTranslator.load(QLocale(), "qt", "_", QLibraryInfo::path(QLibraryInfo::TranslationsPath))) {
        a.installTranslator(&qtTranslator);
    }

    // Load translation based on locale
    QTranslator translator;
    const QStringList uiLanguages = QLocale().uiLanguages();
    for (const QString &locale : uiLanguages) {
        const QString baseName = "oidc-login_" + QLocale(locale).name();
        if (translator.load(":/i18n/" + baseName)) {
            a.installTranslator(&translator);
            break;
        }
    }

    // Ensure that only a single instance of the application is running
    QString lockFilePath = QDir(QStandardPaths::writableLocation(QStandardPaths::TempLocation)).absoluteFilePath("oidc-login.lock");
    QLockFile lockFile(lockFilePath);
    lockFile.setStaleLockTime(0);  // immediately consider a previous lock file as stale to handle crashes
    if (!lockFile.tryLock()) {
        // In auto-login mode (greeter waits for the process) no
        // modal dialog may pop up - the greeter would block until someone
        // clicks "OK". The greeter detects the case via exit code 1 and shows
        // the hint itself. Nothing is written to stderr either: the browser
        // stays silent, the exit code is the whole signal.
        const QByteArray autoLoginEnv = qgetenv("OIDC_AUTOLOGIN");
        const bool autoLogin = !autoLoginEnv.isEmpty()
                && autoLoginEnv.toLower() != "false";
        if (!autoLogin) {
            QMessageBox::information(nullptr, QMessageBox::tr("Application Already Running"), QMessageBox::tr("Another instance of the application is already running."));
        }
        return 1;
    }

    // Show and run the user interface
    MainWindow w;
    w.showFullScreen();
    // Without a window manager Qt does not apply the fullscreen size itself,
    // so apply the screen geometry explicitly (works
    // with and without a WM; with a WM present the fullscreen state stays active).
    if (QScreen *screen = w.screen())
        w.setGeometry(screen->geometry());
    return a.exec();
}
