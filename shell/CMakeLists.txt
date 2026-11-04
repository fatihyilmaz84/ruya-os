cmake_minimum_required(VERSION 3.21)
project(ruya-shell VERSION 0.1.0 LANGUAGES CXX)

option(RUYA_BUILD_TESTS "Build the Qt Quick tests" ON)
# The image build turns this on (image/Containerfile): ruya-shell is then the Wayland compositor
# (compositor/, ADR-002 option A, T-130). Needs QtWaylandCompositor, which the Windows kit lacks.
option(RUYA_COMPOSITOR "Build ruya-shell as the Wayland compositor (Linux)" OFF)

find_package(Qt6 6.8 REQUIRED COMPONENTS Gui Quick Multimedia DBus LinguistTools)
qt_standard_project_setup(REQUIRES 6.8)

# Everything except main() is a static QML module, so the app and the tests share it.
qt_add_library(ruyashell STATIC)

set_source_files_properties(qml/Theme.qml qml/Sfx.qml qml/Notifications.qml qml/ProfileStatus.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

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
        src/audio/DBusAudioBackend.h src/audio/DBusAudioBackend.cpp
        src/audio/Audio.h src/audio/Audio.cpp
        src/network/NetworkBackend.h
        src/network/MockNetworkBackend.h src/network/MockNetworkBackend.cpp
        src/network/DBusNetworkBackend.h src/network/DBusNetworkBackend.cpp
        src/network/Network.h src/network/Network.cpp
        src/bluetooth/BluetoothBackend.h
        src/bluetooth/MockBluetoothBackend.h src/bluetooth/MockBluetoothBackend.cpp
        src/bluetooth/DBusBluetoothBackend.h src/bluetooth/DBusBluetoothBackend.cpp
        src/bluetooth/Bluetooth.h src/bluetooth/Bluetooth.cpp
        src/battery/BatteryBackend.h
        src/battery/MockBatteryBackend.h src/battery/MockBatteryBackend.cpp
        src/battery/DBusBatteryBackend.h src/battery/DBusBatteryBackend.cpp
        src/battery/Batteries.h src/battery/Batteries.cpp
        src/storage/StorageBackend.h
        src/storage/MockStorageBackend.h src/storage/MockStorageBackend.cpp
        src/storage/DBusStorageBackend.h src/storage/DBusStorageBackend.cpp
        src/storage/Storage.h src/storage/Storage.cpp
        src/store/StoreBackend.h
        src/store/MockStoreBackend.h src/store/MockStoreBackend.cpp
        src/store/DBusStoreBackend.h src/store/DBusStoreBackend.cpp
        src/store/Store.h src/store/Store.cpp
        src/library/LibraryBackend.h
        src/library/MockLibraryBackend.h src/library/MockLibraryBackend.cpp
        src/library/DBusLibraryBackend.h src/library/DBusLibraryBackend.cpp
        src/library/Library.h src/library/Library.cpp
        src/update/UpdateBackend.h
        src/update/MockUpdateBackend.h src/update/MockUpdateBackend.cpp
        src/update/DBusUpdateBackend.h src/update/DBusUpdateBackend.cpp
        src/update/Update.h src/update/Update.cpp
        src/session/SessionBackend.h
        src/session/MockSessionBackend.h src/session/MockSessionBackend.cpp
        src/session/DBusSessionBackend.h src/session/DBusSessionBackend.cpp
        src/session/Session.h src/session/Session.cpp
        src/power/PowerBackend.h
        src/power/MockPowerBackend.h src/power/MockPowerBackend.cpp
        src/power/DBusPowerBackend.h src/power/DBusPowerBackend.cpp
        src/power/Power.h src/power/Power.cpp
        src/input/KeyRouter.h src/input/KeyRouter.cpp
    QML_FILES
        qml/Main.qml
        qml/Shell.qml
        qml/Theme.qml
        qml/Sfx.qml
        qml/Notifications.qml
        qml/ProfileStatus.qml
        qml/Setup.qml
        qml/ToastLayer.qml
        qml/VolumeOsd.qml
        qml/Badge.qml
        qml/ButtonGlyph.qml
        qml/HintBar.qml
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
        qml/AppDetailPage.qml
        qml/AppArt.qml
        qml/ArtCard.qml
        qml/HeroBlock.qml
        qml/PrimaryButton.qml
        qml/SecondaryButton.qml
        qml/SectionNav.qml
        qml/GlassPill.qml
        qml/Icon.qml
        qml/LibraryDetailsPage.qml
        qml/SettingsPage.qml
        qml/PowerPage.qml
        qml/PowerConfirm.qml
        qml/SettingsPane.qml
        qml/ProfilesPane.qml
        qml/ProfileAddFlow.qml
        qml/ProfileManageFlow.qml
        qml/ChangePinFlow.qml
        qml/DisplayPane.qml
        qml/AudioPane.qml
        qml/NetworkPane.qml
        qml/BluetoothPane.qml
        qml/StoragePane.qml
        qml/SystemPane.qml
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
        fonts/MaterialSymbolsRounded.ttf
        fonts/MaterialSymbolsRoundedFilled.ttf
        fonts/Inter-Regular.ttf
        fonts/Inter-Light.ttf
        fonts/Inter-SemiBold.ttf
        fonts/Inter-Bold.ttf
)

# qmltyperegistrar includes the QML_ELEMENT headers by file name.
target_include_directories(ruyashell PUBLIC src/profiles src/settings src/audio src/network src/bluetooth src/battery src/storage src/system src/power src/store src/library src/update src/session src/input)
target_link_libraries(ruyashell PRIVATE Qt6::Quick Qt6::Multimedia Qt6::DBus)

# Translations: the .ts files in i18n/ are compiled to .qm and embedded as :/i18n/ruyashell_<lang>.qm.
# English is the source language, but its .ts carries the plural forms ("1 attempt left").
# To add a language: add i18n/ruyashell_<code>.ts here, add the code to DeviceSettings::isValidLanguage
# and to the language rows (SystemPane.qml, Setup.qml). Refresh the .ts files with:
#   cmake --build build-win --config Release --target update_translations
qt_add_translations(ruyashell
    TS_FILES i18n/ruyashell_en.ts i18n/ruyashell_tr.ts
    RESOURCE_PREFIX /i18n
    LUPDATE_OPTIONS -locations relative
)

# Visual Studio generators skip qmltyperegistrar on the first build after a header changed, so a
# new QML_ELEMENT type is "not defined" until the second build, and a removed one breaks the
# compile (T-116). Other generators order these steps correctly.
# See cmake/InvalidateStaleQmlTypes.cmake.
if(CMAKE_GENERATOR MATCHES "Visual Studio")
    get_target_property(ruya_module_sources ruyashell SOURCES)
    set(ruya_registrar_inputs "${CMAKE_CURRENT_LIST_FILE}")   # a type added/removed/renamed
    foreach(source IN LISTS ruya_module_sources)              # a type's header edited
        if(source MATCHES "\\.h$" AND NOT IS_ABSOLUTE "${source}")   # skip generated headers
            list(APPEND ruya_registrar_inputs "${CMAKE_CURRENT_SOURCE_DIR}/${source}")
        endif()
    endforeach()
    list(JOIN ruya_registrar_inputs "|" ruya_registrar_inputs)
    set(ruya_registrar_outputs
        "${CMAKE_CURRENT_BINARY_DIR}/ruyashell_qmltyperegistrations.cpp|${CMAKE_CURRENT_BINARY_DIR}/RuyaShell/ruyashell.qmltypes")
    add_custom_target(ruyashell_invalidate_stale_qmltypes
        COMMAND ${CMAKE_COMMAND} "-DINPUTS=${ruya_registrar_inputs}" "-DOUTPUTS=${ruya_registrar_outputs}"
                -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/InvalidateStaleQmlTypes.cmake"
        VERBATIM)
    add_dependencies(ruyashell ruyashell_invalidate_stale_qmltypes)
endif()

qt_add_executable(ruya-shell src/main.cpp)
target_link_libraries(ruya-shell PRIVATE Qt6::Gui Qt6::Quick ruyashellplugin)

# A module of its own, outside RuyaShell, so qmllint, lupdate and the tests (Windows) never see it.
if(RUYA_COMPOSITOR)
    find_package(Qt6 REQUIRED COMPONENTS WaylandCompositor)
    qt_add_library(ruyacompositor STATIC)
    qt_add_qml_module(ruyacompositor
        URI RuyaCompositor
        VERSION 1.0
        QML_FILES compositor/Compositor.qml
    )
    target_link_libraries(ruyacompositor PRIVATE Qt6::Quick Qt6::WaylandCompositor)
    target_link_libraries(ruya-shell PRIVATE ruyacompositorplugin Qt6::WaylandCompositor)
    target_compile_definitions(ruya-shell PRIVATE RUYA_COMPOSITOR)
endif()

include(GNUInstallDirs)
install(TARGETS ruya-shell RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
# Licences of the bundled fonts (T-157, T-145).
install(FILES fonts/LICENSE-MaterialSymbols.txt fonts/OFL-Inter.txt DESTINATION share/licenses/ruyaos)

if(RUYA_BUILD_TESTS)
    find_package(Qt6 REQUIRED COMPONENTS QuickTest)
    enable_testing()
    qt_add_executable(tst_ruyashell tests/tst_main.cpp)
    target_link_libraries(tst_ruyashell PRIVATE Qt6::Quick Qt6::QuickTest ruyashellplugin)
    target_compile_definitions(tst_ruyashell PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests")
    add_test(NAME qml COMMAND tst_ruyashell)
    set_tests_properties(qml PROPERTIES ENVIRONMENT "RUYA_SERVICES=mock")
endif()
