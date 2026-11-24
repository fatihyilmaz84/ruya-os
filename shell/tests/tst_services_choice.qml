import QtQuick
import QtTest
import RuyaShell

// Which backend a facade picks from RUYA_SERVICES (RUY-919): mock, dbus and unset give the right
// answer for this OS. tst_main.cpp runs ruya::useMockServices() and hands the verdict over.
// The Linux branch (only "mock" is the mock) is host-unverifiable on Windows.
TestCase {
    name: "ServicesChoice"

    function test_choice_follows_RUYA_SERVICES() {
        compare(servicesChoice, "", "mock, dbus and unset RUYA_SERVICES: " + servicesChoice)
    }
}
