#include "ui/Application.h"
#include <QApplication>

int main(int argc, char **argv) {
    QApplication qapp(argc, argv);
    Application app;
    return app.run(argc, argv);
}
