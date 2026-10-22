cmake_minimum_required(VERSION 3.21)
project(ruya-shell VERSION 0.1.0 LANGUAGES CXX)

find_package(Qt6 6.5 REQUIRED COMPONENTS Gui Quick Multimedia)
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(ruya-shell src/main.cpp)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(ruya-shell
    URI RuyaShell
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/Tile.qml
        qml/Backdrop.qml
        qml/FpsMeter.qml
    RESOURCES
        sounds/navigate.wav
        sounds/select.wav
        sounds/back.wav
)

target_link_libraries(ruya-shell PRIVATE Qt6::Gui Qt6::Quick Qt6::Multimedia)

include(GNUInstallDirs)
install(TARGETS ruya-shell RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
