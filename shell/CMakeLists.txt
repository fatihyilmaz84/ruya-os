cmake_minimum_required(VERSION 3.21)
project(ruya-shell VERSION 0.1.0 LANGUAGES C CXX)

option(RUYA_BUILD_TESTS "Build the Qt Quick tests" ON)
# The image build turns this on (image/Containerfile): ruya-shell is then the Wayland compositor
# (compositor/, ADR-002 option A, T-130). Needs QtWaylandCompositor, which the Windows kit lacks.
option(RUYA_COMPOSITOR "Build ruya-shell as the Wayland compositor (Linux)" OFF)
# The bundled sound theme (T-227, T-294) is installed as files (/usr/share/ruyaos/sounds/dreamglass) and the shell
# reads it there, so the image build (RUYA_COMPOSITOR=ON) does not embed a second copy of its 1.1 MB. The Windows
# build and the Linux test build keep the resource (the dev build's theme, and the fallback if the folder is missing).
if(RUYA_COMPOSITOR)
    set(_ruya_sounds_default OFF)
else()
    set(_ruya_sounds_default ON)
endif()
option(RUYA_SOUNDS_RESOURCE "Embed the bundled sound theme in the binary" ${_ruya_sounds_default})

find_package(Qt6 6.8 REQUIRED COMPONENTS Gui Network Quick Multimedia DBus LinguistTools)
# ScreenPower (T-202) calls QPlatformScreen::setPowerState, a private QPA header. `GuiPrivate` is a
# find_package component only from Qt 6.9; Qt 6.8 (the floor, root CLAUDE.md) offers Qt6::GuiPrivate
# with the Gui package, so asking for the component there would fail the configure step.
if(Qt6_VERSION VERSION_GREATER_EQUAL 6.9)
    find_package(Qt6 6.9 REQUIRED COMPONENTS GuiPrivate)
endif()
# ShaderTools builds the liquid pill's shader (T-205). It is optional: without it the .qsb is not
# in the module, the ShaderEffect reports an error and GlassPill shows the plain pill.
find_package(Qt6 6.8 OPTIONAL_COMPONENTS ShaderTools)
qt_standard_project_setup(REQUIRES 6.8)

# Everything except main() is a static QML module, so the app and the tests share it.
qt_add_library(ruyashell STATIC)

set_source_files_properties(qml/Theme.qml qml/Sfx.qml qml/Notifications.qml qml/DeviceIcons.qml qml/BluetoothText.qml qml/SoundThemeText.qml qml/ProfileStatus.qml qml/DurationText.qml qml/DisplayText.qml qml/BackKey.qml qml/ThermalText.qml qml/GlareGate.qml qml/LiquidGate.qml qml/IdleClock.qml qml/themes/Themes.qml qml/themes/ThemeMath.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(ruyashell
    URI RuyaShell
    VERSION 1.0
    OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/RuyaShell   # lets qmllint resolve the module
    SOURCES
        src/backend/RequestSequence.h
        src/profiles/ProfilesBackend.h
        src/profiles/MockProfilesBackend.h src/profiles/MockProfilesBackend.cpp
        src/profiles/DBusProfilesBackend.h src/profiles/DBusProfilesBackend.cpp
        src/profiles/Profiles.h src/profiles/Profiles.cpp
        src/settings/DeviceSettings.h src/settings/DeviceSettings.cpp
        src/system/SystemInfo.h src/system/SystemInfo.cpp
        src/system/SystemDetailsBackend.h
        src/system/MockSystemDetailsBackend.h src/system/MockSystemDetailsBackend.cpp
        src/system/DBusSystemDetailsBackend.h src/system/DBusSystemDetailsBackend.cpp
        src/system/SystemDetails.h src/system/SystemDetails.cpp
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
        src/time/TimeBackend.h
        src/time/MockTimeBackend.h src/time/MockTimeBackend.cpp
        src/time/DBusTimeBackend.h src/time/DBusTimeBackend.cpp
        src/time/TimeZone.h src/time/TimeZone.cpp
        src/display/DisplayBackend.h
        src/display/MockDisplayBackend.h src/display/MockDisplayBackend.cpp
        src/display/DBusDisplayBackend.h src/display/DBusDisplayBackend.cpp
        src/display/Display.h src/display/Display.cpp
        src/thermal/ThermalBackend.h
        src/thermal/MockThermalBackend.h src/thermal/MockThermalBackend.cpp
        src/thermal/DBusThermalBackend.h src/thermal/DBusThermalBackend.cpp
        src/thermal/Thermal.h src/thermal/Thermal.cpp
        src/storage/StorageBackend.h
        src/storage/MockStorageBackend.h src/storage/MockStorageBackend.cpp
        src/storage/DBusStorageBackend.h src/storage/DBusStorageBackend.cpp
        src/storage/Storage.h src/storage/Storage.cpp
        src/store/StoreBackend.h src/store/JobBook.h src/store/JobBook.cpp
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
        src/usage/UsageBackend.h
        src/usage/MockUsageBackend.h src/usage/MockUsageBackend.cpp
        src/usage/DBusUsageBackend.h src/usage/DBusUsageBackend.cpp
        src/usage/UsageStats.h src/usage/UsageStats.cpp
        src/usage/Usage.h src/usage/Usage.cpp
        src/power/PowerBackend.h
        src/power/MockPowerBackend.h src/power/MockPowerBackend.cpp
        src/power/DBusPowerBackend.h src/power/DBusPowerBackend.cpp
        src/power/Power.h src/power/Power.cpp
        src/power/IdleInhibit.h src/power/IdleInhibit.cpp
        src/power/MonotonicClock.h src/power/MonotonicClock.cpp
        src/power/ScreenPower.h src/power/ScreenPower.cpp
        src/input/KeyRouter.h src/input/KeyRouter.cpp
        src/wallpaper/Wallpapers.h src/wallpaper/Wallpapers.cpp
        src/art/ArtPalette.h src/art/ArtPalette.cpp src/art/MockArt.h
        src/sound/SoundThemeCheck.h src/sound/SoundThemeCheck.cpp
        src/sound/SoundThemes.h src/sound/SoundThemes.cpp
    QML_FILES
        qml/Main.qml
        qml/Shell.qml
        qml/Theme.qml
        qml/themes/ThemeSet.qml
        qml/themes/Themes.qml
        qml/themes/ThemeMath.qml
        qml/Sfx.qml
        qml/AmbientLoop.qml
        qml/BackKey.qml
        qml/ThermalText.qml
        qml/Notifications.qml
        qml/DeviceIcons.qml
        qml/BluetoothText.qml
        qml/ProfileStatus.qml
        qml/SoundThemeText.qml
        qml/DisplayText.qml
        qml/ModeConfirm.qml
        qml/ModePicker.qml
        qml/Setup.qml
        qml/ToastLayer.qml
        qml/VolumeOsd.qml
        qml/Badge.qml
        qml/ButtonGlyph.qml
        qml/HintBar.qml
        qml/Backdrop.qml
        qml/WallpaperLayer.qml
        qml/WallpaperPicker.qml
        qml/FpsMeter.qml
        qml/ProfilePicker.qml
        qml/ControllerPairHint.qml
        qml/ControllerOnboarding.qml
        qml/ControllerToasts.qml
        qml/ButtonTest.qml
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
        qml/FocusGlide.qml
        qml/LiquidGlass.qml
        qml/LiquidGate.qml
        qml/IdleClock.qml
        qml/ScreenSaver.qml
        qml/PowerSavingPane.qml
        qml/GlassPill.qml
        qml/GlassLayers.qml
        qml/GlassRim.qml
        qml/GlassShadow.qml
        qml/GlassSheet.qml
        qml/ModalLayer.qml
        qml/CardFocusLayers.qml
        qml/GlareGate.qml
        qml/Icon.qml
        qml/BatteryChip.qml
        qml/BatteryMore.qml
        qml/BatteryListModal.qml
        qml/LibraryDetailsPage.qml
        qml/SettingsPage.qml
        qml/PowerPage.qml
        qml/PowerConfirm.qml
        qml/ThermalNotice.qml
        qml/ThermalPolicy.qml
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
        qml/ZoneChooser.qml
        qml/ZonePicker.qml
        qml/AboutPane.qml
        qml/SystemInfoPage.qml
        qml/SystemInfoRows.qml
        qml/ActivityPage.qml
        qml/ActivityGamePage.qml
        qml/BarChart.qml
        qml/DurationText.qml
        qml/UsagePresence.qml
        qml/controls/ChartRow.qml
        qml/controls/SettingControl.qml
        qml/controls/SettingRow.qml
        qml/controls/ToggleRow.qml
        qml/controls/ChoiceRow.qml
        qml/controls/SliderRow.qml
        qml/controls/ThemeRow.qml
    RESOURCES
        assets/glass-grain.png
        assets/wallpapers/catalog.json
        assets/wallpapers/dusk.jpg
        assets/wallpapers/aurora.jpg
        assets/wallpapers/ember.jpg
        assets/wallpapers/lagoon.jpg
        assets/wallpapers/orchid.jpg
        assets/wallpapers/daybreak.jpg
        fonts/MaterialSymbolsRounded.ttf
        fonts/MaterialSymbolsRoundedFilled.ttf
        fonts/Inter-Regular.ttf
        fonts/Inter-Light.ttf
        fonts/Inter-SemiBold.ttf
        fonts/Inter-Bold.ttf
)

if(RUYA_SOUNDS_RESOURCE)
    qt_target_qml_sources(ruyashell
        RESOURCES
            sounds/dreamglass/navigate.wav
            sounds/dreamglass/select.wav
            sounds/dreamglass/back.wav
            sounds/dreamglass/error.wav
            sounds/dreamglass/notification.wav
            sounds/dreamglass/warning.wav
            sounds/dreamglass/open.wav
            sounds/dreamglass/close.wav
            sounds/dreamglass/page.wav
            sounds/dreamglass/volume.wav
            sounds/dreamglass/startup.wav
            sounds/dreamglass/toggle-on.wav
            sounds/dreamglass/toggle-off.wav
            sounds/dreamglass/ambient.flac
            sounds/dreamglass/theme.json
            sounds/dreamglass/README.md
            sounds/dreamglass/LICENSE-Sounds.txt
    )
endif()

# Precompiled shaders (04 §3.8 liquid pill, T-205): GLSL 440 -> .qsb for every backend, embedded at
# qrc:/qt/qml/RuyaShell/qml/shaders/, next to the QML files. Never inline GLSL in QML.
if(TARGET Qt6::ShaderTools)
    qt_add_shaders(ruyashell "ruyashell_shaders"
        PREFIX "/qt/qml/RuyaShell/qml"
        FILES shaders/liquid.frag
    )
else()
    message(WARNING "Qt6 ShaderTools not found: the liquid pill falls back to the plain pill")
endif()

# qmltyperegistrar includes the QML_ELEMENT headers by file name.
target_include_directories(ruyashell PUBLIC src/backend src/profiles src/settings src/audio src/network src/bluetooth src/battery src/time src/display src/thermal src/storage src/system src/power src/store src/library src/update src/session src/usage src/input src/wallpaper src/sound src/art)
# Qt6::GuiPrivate: ScreenPower calls QPlatformScreen::setPowerState (DPMS under eglfs_kms, T-202).
target_link_libraries(ruyashell PRIVATE Qt6::Network Qt6::Quick Qt6::Multimedia Qt6::DBus Qt6::GuiPrivate)

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
target_include_directories(ruya-shell PRIVATE src/sound)   # --check-sound-theme (T-227) uses the checker without the UI

# A module of its own, outside RuyaShell, so qmllint, lupdate and the tests (Windows) never see it.
if(RUYA_COMPOSITOR)
    find_package(Qt6 REQUIRED COMPONENTS WaylandCompositor)
    qt_add_library(ruyacompositor STATIC)
    qt_add_qml_module(ruyacompositor
        URI RuyaCompositor
        VERSION 1.0
        QML_FILES compositor/Compositor.qml
        SOURCES compositor/IdleInhibitManager.h compositor/IdleInhibitManager.cpp
    )
    # The Wayland idle-inhibit protocol (T-202): qtwaylandscanner writes the server glue from the XML.
    qt6_generate_wayland_protocol_server_sources(ruyacompositor
        FILES ${CMAKE_CURRENT_SOURCE_DIR}/compositor/idle-inhibit-unstable-v1.xml)
    # qmltyperegistrar emits __has_include(<IdleInhibitManager.h>); qt_add_qml_module adds only the
    # target's source dir to the include path (QTBUG-93443), so list the folder of the headers.
    target_include_directories(ruyacompositor PRIVATE compositor)
    target_link_libraries(ruyacompositor PRIVATE Qt6::Quick Qt6::WaylandCompositor)
    target_link_libraries(ruya-shell PRIVATE ruyacompositorplugin Qt6::WaylandCompositor)
    target_compile_definitions(ruya-shell PRIVATE RUYA_COMPOSITOR)
endif()

include(GNUInstallDirs)
install(TARGETS ruya-shell RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
# Licences of the bundled fonts (T-157, T-145) and wallpapers (T-208).
install(FILES fonts/LICENSE-MaterialSymbols.txt fonts/OFL-Inter.txt assets/wallpapers/LICENSE-Wallpapers.txt DESTINATION share/licenses/ruyaos)
# The bundled sound theme (T-227): the shell looks in /usr/share/ruyaos/sounds first (a Qt resource is the fallback).
install(DIRECTORY sounds/dreamglass DESTINATION share/ruyaos/sounds)
install(FILES sounds/dreamglass/LICENSE-Sounds.txt DESTINATION share/licenses/ruyaos)

if(RUYA_BUILD_TESTS)
    find_package(Qt6 REQUIRED COMPONENTS QuickTest)
    enable_testing()
    qt_add_executable(tst_ruyashell tests/tst_main.cpp)
    target_link_libraries(tst_ruyashell PRIVATE Qt6::Quick Qt6::QuickTest ruyashellplugin)
    target_include_directories(tst_ruyashell PRIVATE src/settings)   # the theme-persistence check in tst_main.cpp
    target_compile_definitions(tst_ruyashell PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests")
    add_test(NAME qml COMMAND tst_ruyashell)
    set_tests_properties(qml PROPERTIES ENVIRONMENT "RUYA_SERVICES=mock")
endif()
