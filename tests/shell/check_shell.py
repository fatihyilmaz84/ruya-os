"""Host-side smoke test for the QML shell, using PySide6's bundled Qt (no Qt SDK, no VM).

    python -m pip install PySide6==6.8.1
    python tests/shell/check_shell.py [--keep-open]

Opens a real GPU-backed window for a few seconds (the offscreen platform falls back to the
software renderer, which cannot run MultiEffect). It drives the UI with key events, asserts
navigation and overlay focus rules, and saves screenshots to output/shell-shots/.
Frame rates printed here are from the dev machine, not KPI data.
"""
import os
import shutil
import sys
import tempfile
from pathlib import Path

from PySide6.QtCore import QObject, Qt, QTimer, qInstallMessageHandler
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuick import QQuickWindow  # noqa: F401  (registers the QQuickWindow wrapper)
from PySide6.QtTest import QTest

REPO = Path(__file__).resolve().parents[2]
SHOTS = REPO / "output" / "shell-shots"


def stage_module(tmp: Path) -> None:
    """Mirror what qt_add_qml_module does: a RuyaShell module dir with a qmldir."""
    mod = tmp / "RuyaShell"
    (mod / "sounds").mkdir(parents=True)
    for qml in (REPO / "shell" / "qml").glob("*.qml"):
        text = qml.read_text(encoding="utf-8")
        if qml.name == "Main.qml":
            # Windowed for the test; resources resolved from disk instead of qrc.
            text = text.replace("    visibility: Window.FullScreen", "    // fullscreen disabled by check_shell.py")
            text = text.replace("qrc:/qt/qml/RuyaShell/sounds/", "sounds/")
        (mod / qml.name).write_text(text, encoding="utf-8")
    for wav in (REPO / "shell" / "sounds").glob("*.wav"):
        shutil.copy(wav, mod / "sounds" / wav.name)
    lines = ["module RuyaShell"]
    for qml in sorted((REPO / "shell" / "qml").glob("*.qml")):
        prefix = "singleton " if qml.stem == "Theme" else ""
        lines.append(f"{prefix}{qml.stem} 1.0 {qml.name}")
    (mod / "qmldir").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    warnings: list[str] = []
    failures: list[str] = []

    def on_message(mode, _ctx, msg):
        if mode.name in ("QtWarningMsg", "QtCriticalMsg", "QtFatalMsg"):
            warnings.append(msg)

    qInstallMessageHandler(on_message)
    app = QGuiApplication(sys.argv)
    tmp = Path(tempfile.mkdtemp(prefix="ruya-shell-"))
    stage_module(tmp)

    engine = QQmlApplicationEngine()
    engine.addImportPath(str(tmp))
    engine.setInitialProperties({"version": "0.0.0-hostcheck"})
    engine.loadFromModule("RuyaShell", "Main")
    if not engine.rootObjects():
        print("FAIL: shell did not load\n  " + "\n  ".join(warnings))
        return 1

    win = engine.rootObjects()[0]
    win.resize(960, 540)
    win.setPosition(40, 40)
    win.show()
    frames = []
    win.frameSwapped.connect(lambda: frames.append(1))

    SHOTS.mkdir(parents=True, exist_ok=True)
    tiles = lambda: win.findChild(QObject, "tiles")  # noqa: E731
    focus_name = lambda: win.activeFocusItem().objectName() if win.activeFocusItem() else None  # noqa: E731

    def expect(cond: bool, what: str):
        print(("ok   " if cond else "FAIL ") + what)
        if not cond:
            failures.append(what)

    steps = [
        lambda: expect(tiles().property("activeFocus"), "tiles have focus at start"),
        lambda: win.grabWindow().save(str(SHOTS / "1-home.png")),
        lambda: QTest.keyClick(win, Qt.Key_Right),
        lambda: QTest.keyClick(win, Qt.Key_Right),
        lambda: expect(tiles().property("currentIndex") == 2, "Right x2 moves to index 2"),
        lambda: QTest.keyClick(win, Qt.Key_Left),
        lambda: expect(tiles().property("currentIndex") == 1, "Left moves back"),
        lambda: QTest.keyClick(win, Qt.Key_Return),
        lambda: win.grabWindow().save(str(SHOTS / "2-navigated.png")),
        lambda: QTest.keyClick(win, Qt.Key_HomePage),
        lambda: None,
        lambda: expect(focus_name() == "systemPanelFocus", "Guide opens overlay and it takes focus"),
        lambda: win.grabWindow().save(str(SHOTS / "3-overlay.png")),
        lambda: QTest.keyClick(win, Qt.Key_Right),
        lambda: expect(tiles().property("currentIndex") == 1, "overlay is modal (Right swallowed)"),
        lambda: QTest.keyClick(win, Qt.Key_Escape),
        lambda: None,
        lambda: expect(tiles().property("activeFocus"), "Back closes overlay and focus returns to tiles"),
        lambda: expect(len(frames) > 10, f"frames are being presented ({len(frames)})"),
        lambda: app.quit() if "--keep-open" not in sys.argv else None,
    ]

    def run(i=0):
        steps[i]()
        if i + 1 < len(steps):
            QTimer.singleShot(400, lambda: run(i + 1))

    QTimer.singleShot(1000, run)
    QTimer.singleShot(60000, lambda: (failures.append("timeout"), app.quit()))
    app.exec()

    # Missing system fonts on Windows-only paths are not shell problems.
    real = [w for w in warnings if "QFontDatabase" not in w]
    expect(not real, "no QML warnings" + ("".join("\n       " + w for w in real)))
    print(f"screenshots: {SHOTS}")
    shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    code = main()
    sys.stdout.flush()
    os._exit(code)   # PySide6 can hang on interpreter teardown with a live engine
