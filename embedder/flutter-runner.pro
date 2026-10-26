TEMPLATE = app
TARGET = flutter-sailfish-runner
QT += gui
CONFIG += c++14 link_pkgconfig
SOURCES += src/main.cpp

# Directory holding the aarch64 libflutter_engine.so to link against, given as the environment
# variable ENGINE_LIB_DIR (scripts/build-runner.sh sets it). The API header is vendored.
ENGINE_LIB_DIR = $$(ENGINE_LIB_DIR)
isEmpty(ENGINE_LIB_DIR): error("set ENGINE_LIB_DIR to the directory with libflutter_engine.so")

INCLUDEPATH += $$PWD/third_party/flutter_engine $$PWD/third_party/flutter_client_wrapper/include
LIBS += -L$$ENGINE_LIB_DIR -lflutter_engine -ldl -Wl,-rpath,/usr/libexec/flutter-sailfish
