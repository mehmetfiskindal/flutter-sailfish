TEMPLATE = app
TARGET = flutter-sailfish-runner
QT += gui
CONFIG += c++14 link_pkgconfig
SOURCES += src/main.cpp

ENGINE_DIR = $$PWD/../engine/prebuilt-linux-arm64/embedder
INCLUDEPATH += $$ENGINE_DIR
LIBS += -L$$ENGINE_DIR -lflutter_engine -Wl,-rpath,/usr/libexec/flutter-sailfish
