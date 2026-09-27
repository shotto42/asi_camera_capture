// camera_selector_test.cpp
//
// Headless camera-selector-dialog suite (run via ./camera_app --seltest):
// drives the REAL pre-GUI selection dialog (showCameraSelector) with
// synthetic input offscreen and pins its interaction model —
//
//   * there is NO Ok button: an entry is confirmed by CLICKING it, or with
//     Return/Enter on the highlighted row (arrow keys move the highlight);
//   * the only remaining button is Cancel — Esc or a click on it exits
//     (returns -1);
//   * Cancel is the wider button (min-width from the dialog's scoped
//     stylesheet, not just as wide as its text).
//
// No camera needed: two synthetic CameraOptions stand in for a connected
// pair (ids 101/102 are not real CameraIDs on this bench).

#include "camera_selector.h"
#include "test_suites.h"

#include <QApplication>
#include <QDialog>
#include <QDialogButtonBox>
#include <QListWidget>
#include <QPushButton>
#include <QTimer>
#include <QtTest/QtTest>

#include <cstdio>
#include <functional>
#include <vector>

namespace
{

// The two synthetic bodies: their ids are what showCameraSelector returns.
std::vector<CameraOption> testCams = {
    { 0, 101, "ZWO ASI178MC", "colour · 3096×2080" },
    { 1, 102, "ZWO ASI178MM", "mono · 3096×2080" },
};

// One pass over the whole dialog: schedule a timer that drives the open
// dialog from inside its own event loop (it fires while exec() runs), then
// check the CameraID showCameraSelector returned.
template <typename Fn>
bool runScenario(const char* name, int expected, Fn fn)
{
    bool fired = false;
    QTimer::singleShot(150, [&]() {
        auto* dlg = qobject_cast<QDialog*>(QApplication::activeModalWidget());
        if (dlg) { fired = true; fn(dlg); }
    });
    const int got = showCameraSelector(testCams);
    const bool ok = fired && (got == expected);
    std::printf("SELTEST %-26s got=%d want=%d -> %s\n", name, got, expected,
                ok ? "ok" : "FAIL");
    return ok;
}

}   // namespace

bool runCameraSelectorSelfTest()
{
    qputenv("QT_QPA_PLATFORM", "offscreen");
    static int argc = 1;
    static char prog[] = "camera_app";
    char* argv[] = { prog, nullptr };
    QApplication app(argc, argv);

    bool ok = true;

    // 1) Mouse: clicking the SECOND entry confirms that camera.
    ok = runScenario("mouse-click-entry-1", 102, [](QDialog* d) {
        auto* list = d->findChild<QListWidget*>("camSelList");
        if (!list || list->count() < 2) return;
        QTest::mouseClick(list->viewport(), Qt::LeftButton, Qt::NoModifier,
                          list->visualItemRect(list->item(1)).center());
    }) && ok;

    // 2) Keyboard: arrow moves the highlight, Return confirms it.
    ok = runScenario("keys-down-then-return", 102, [](QDialog* d) {
        auto* list = d->findChild<QListWidget*>("camSelList");
        if (!list) return;
        list->setFocus();   // the dialog gives the list the focus on open
        QTest::keyClick(list, Qt::Key_Down);
        QTest::keyClick(list, Qt::Key_Return);
    }) && ok;

    // 3) Keyboard: bare Return confirms the preselected (first) entry.
    ok = runScenario("keys-return-first-row", 101, [](QDialog* d) {
        auto* list = d->findChild<QListWidget*>("camSelList");
        if (!list) return;
        list->setFocus();
        QTest::keyClick(list, Qt::Key_Return);
    }) && ok;

    // 4) Esc exits without a choice.
    ok = runScenario("key-escape-cancels", -1, [](QDialog* d) {
        auto* list = d->findChild<QListWidget*>("camSelList");
        if (!list) return;
        list->setFocus();
        QTest::keyClick(list, Qt::Key_Escape);
    }) && ok;

    // 5) Clicking the (wider) Cancel button exits without a choice.
    ok = runScenario("mouse-click-cancel", -1, [](QDialog* d) {
        auto* cancel = d->findChild<QPushButton*>("camSelCancel");
        if (!cancel) return;
        QTest::mouseClick(cancel, Qt::LeftButton);
    }) && ok;

    // 6) Structure while the dialog is open: no Ok button, and Cancel is
    //    at least 170 px wide (the scoped stylesheet's min-width — the
    //    button must not be "just as wide as the text").
    {
        bool structureOk = false, fired = false;
        QTimer::singleShot(150, [&]() {
            auto* dlg = qobject_cast<QDialog*>(QApplication::activeModalWidget());
            if (!dlg) return;
            fired = true;
            auto* box = dlg->findChild<QDialogButtonBox*>();
            auto* cancel = box ? box->button(QDialogButtonBox::Cancel) : nullptr;
            std::printf("SELTEST   diag: box=%d okBtn=%d cancel=%d cancelW=%d\n",
                        box ? 1 : 0, box ? (box->button(QDialogButtonBox::Ok) ? 1 : 0) : -1,
                        cancel ? 1 : 0, cancel ? cancel->width() : -1);
            structureOk = box && !box->button(QDialogButtonBox::Ok)
                          && cancel && cancel->width() >= 170;
            dlg->reject();
        });
        const int got = showCameraSelector(testCams);
        ok = fired && structureOk && (got == -1) && ok;
        std::printf("SELTEST %-26s -> %s\n", "layout-no-ok-wide-cancel",
                    ok ? "ok" : "FAIL");
    }

    std::printf("SELTEST %s\n", ok ? "PASS" : "FAIL");
    return ok;
}
