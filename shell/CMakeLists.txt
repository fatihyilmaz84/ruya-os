cmake_minimum_required(VERSION 3.21)
project(ruya-shell VERSION 0.1.0 LANGUAGES CXX)

option(RUYA_BUILD_TESTS "Build the Qt Quick tests" ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Gui Quick Multimedia DBus)
qt_standard_project_setup(REQUIRES 6.8)

# Everything except main() is a static QML module, so the app and the tests share it.
qt_add_library(ruyashell STATIC)

set_source_files_properties(qml/Theme.qml qml/Sfx.qml qml/Notifications.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(ruyashell
    URI RuyaShell
    VERSION 1.0
    OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/RuyaShell   # lets qmllint resolve the module
    SOURCES
        src/profiles/ProfilesBackend.h
        src/profiles/MockProfilesBackend.h src/profiles/MockProfilesBackend.cpp
        src/profiles/DBusProfilesBackend.h src/profiles/DBusProfilesBackend.cpp
        src/profiles/Profiles.h src/profiles/Profiles.cpp
        src/settings/DeviceSettings.h src/settings/DeviceSettings.cpp
        src/system/SystemInfo.h src/system/SystemInfo.cpp
        src/audio/AudioBackend.h
        src/audio/MockAudioBackend.h src/audio/MockAudioBackend.cpp
        src/audio/Audio.h src/audio/Audio.cpp
    QML_FILES
        qml/Main.qml
        qml/Shell.qml
        qml/Theme.qml
        qml/Sfx.qml
        qml/Notifications.qml
        qml/ToastLayer.qml
        qml/VolumeOsd.qml
        qml/Tile.qml
        qml/Backdrop.qml
        qml/FpsMeter.qml
        qml/ProfilePicker.qml
        qml/ProfileCard.qml
        qml/PinPad.qml
        qml/TextEntry.qml
        qml/Page.qml
        qml/ComingSoon.qml
        qml/GamesPage.qml
        qml/MediaPage.qml
        qml/StorePage.qml
        qml/SettingsPage.qml
        qml/PowerPage.qml
        qml/SettingsPane.qml
        qml/DisplayPane.qml
        qml/AboutPane.qml
        qml/controls/SettingControl.qml
        qml/controls/SettingRow.qml
        qml/controls/ToggleRow.qml
        qml/controls/ChoiceRow.qml
        qml/controls/SliderRow.qml
    RESOURCES
        sounds/navigate.wav
        sounds/select.wav
        sounds/back.wav
)

# qmltyperegistrar includes the QML_ELEMENT headers by file name.
target_include_directories(ruyashell PUBLIC src/profiles src/settings src/audio src/system)
target_link_libraries(ruyashell PRIVATE Qt6::Quick Qt6::Multimedia Qt6::DBus)

qt_add_executable(ruya-shell src/main.cpp)
target_link_libraries(ruya-shell PRIVATE Qt6::Gui Qt6::Quick ruyashellplugin)

include(GNUInstallDirs)
install(TARGETS ruya-shell RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

if(RUYA_BUILD_TESTS)
    find_package(Qt6 REQUIRED COMPONENTS QuickTest)
    enable_testing()
    qt_add_executable(tst_ruyashell tests/tst_main.cpp)
    target_link_libraries(tst_ruyashell PRIVATE Qt6::Quick Qt6::QuickTest ruyashellplugin)
    target_compile_definitions(tst_ruyashell PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests")
    add_test(NAME qml COMMAND tst_ruyashell)
    set_tests_properties(qml PROPERTIES ENVIRONMENT "RUYA_SERVICES=mock")
endif()
