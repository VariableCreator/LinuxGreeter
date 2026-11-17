#ifndef CUSTOMWEBENGINEVIEW_H
#define CUSTOMWEBENGINEVIEW_H

#include <QWebEngineView>


class CustomWebEngineView : public QWebEngineView
{
    Q_OBJECT

public:
    explicit CustomWebEngineView(QWidget *parent = nullptr) : QWebEngineView(parent) {}
protected:
    QWebEngineView* createWindow(QWebEnginePage::WebWindowType type) override;
};

#endif // CUSTOMWEBENGINEVIEW_H
