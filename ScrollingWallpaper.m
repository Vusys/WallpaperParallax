/*
 * ScrollingWallpaper - Parallax wallpaper scrolling for iOS 6
 * Makes the homescreen wallpaper pan with page swipes, like Android.
 *
 * Build (on device):
 *   clang -I/var/sdk/usr/local/include -dynamiclib -lsubstrate -lobjc \
 *     -o /tmp/ScrollingWallpaper.dylib ScrollingWallpaper.m
 *   ldid -S /tmp/ScrollingWallpaper.dylib
 */

#include <objc/runtime.h>
#include <objc/message.h>

/* --- Core Graphics types (no SDK headers available) --- */

typedef struct { float x, y; } CGPoint;
typedef struct { float width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
typedef struct { float a, b, c, d, tx, ty; } CGAffineTransform;

/* --- MobileSubstrate --- */

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

/* --- Typed objc_msgSend casts --- */

typedef void *(*msg_id)(void *, SEL);

/*
 * armv7 ABI: any struct > 4 bytes is returned via stret (hidden first param).
 * CGPoint (8), CGSize (8), CGRect (16) ALL need objc_msgSend_stret.
 */
typedef void (*msg_point_stret)(CGPoint *, void *, SEL);
typedef void (*msg_size_stret)(CGSize *, void *, SEL);
typedef void (*msg_rect_stret)(CGRect *, void *, SEL);

/* setTransform: takes CGAffineTransform by value */
typedef void (*msg_setTransform)(void *, SEL, CGAffineTransform);

/* --- Constants --- */

static const float kScale = 1.08f;  /* 8% zoom to hide edges */

/* --- State --- */

static float sProgress     = 0.0f;  /* 0.0 = first page, 1.0 = last */
static BOOL  sAppLaunching = NO;    /* suppress during app transitions */

/* --- Helper: apply parallax transform to wallpaper view --- */

static void applyWallpaperTransform(void) {
    Class SBUICtrlCls = objc_getClass("SBUIController");
    void *uiCtrl = ((msg_id)objc_msgSend)((void *)SBUICtrlCls,
                                           sel_registerName("sharedInstance"));
    void *wpView = ((msg_id)objc_msgSend)(uiCtrl,
                                           sel_registerName("wallpaperView"));
    if (!wpView) return;

    CGRect wpBounds;
    ((msg_rect_stret)objc_msgSend_stret)(&wpBounds, wpView,
                                          sel_registerName("bounds"));

    float panRange = (kScale - 1.0f) * wpBounds.size.width;
    float xShift   = (0.5f - sProgress) * panRange;

    CGAffineTransform t = {
        kScale, 0.0f,
        0.0f,   kScale,
        xShift, 0.0f
    };
    ((msg_setTransform)objc_msgSend)(wpView,
                                      sel_registerName("setTransform:"), t);
}

/* --- Helper: read scroll progress from icon scroll view --- */

static float readScrollProgress(void) {
    Class SBIconCtrlCls = objc_getClass("SBIconController");
    void *iconCtrl = ((msg_id)objc_msgSend)((void *)SBIconCtrlCls,
                                             sel_registerName("sharedInstance"));
    void *sv = ((msg_id)objc_msgSend)(iconCtrl,
                                       sel_registerName("scrollView"));
    if (!sv) return 0.0f;

    CGPoint offset;
    ((msg_point_stret)objc_msgSend_stret)(&offset, sv,
                                           sel_registerName("contentOffset"));
    CGSize csize;
    ((msg_size_stret)objc_msgSend_stret)(&csize, sv,
                                          sel_registerName("contentSize"));
    CGRect bounds;
    ((msg_rect_stret)objc_msgSend_stret)(&bounds, sv,
                                          sel_registerName("bounds"));

    float maxOff = csize.width - bounds.size.width;
    if (maxOff <= 0.0f) return 0.0f;

    float p = offset.x / maxOff;
    if (p < 0.0f) p = 0.0f;
    if (p > 1.0f) p = 1.0f;
    return p;
}

/* ============================================================
 * HOOK 1: SBIconController -scrollViewDidScroll:
 * Normal scroll tracking — skipped during app transitions.
 * ============================================================ */

static void (*orig_scrollViewDidScroll)(void *, SEL, void *);

static void hook_scrollViewDidScroll(void *self, SEL _cmd, void *scrollView) {
    orig_scrollViewDidScroll(self, _cmd, scrollView);

    if (sAppLaunching) return;

    CGPoint offset;
    ((msg_point_stret)objc_msgSend_stret)(&offset, scrollView,
                                           sel_registerName("contentOffset"));
    CGSize csize;
    ((msg_size_stret)objc_msgSend_stret)(&csize, scrollView,
                                          sel_registerName("contentSize"));
    CGRect bounds;
    ((msg_rect_stret)objc_msgSend_stret)(&bounds, scrollView,
                                          sel_registerName("bounds"));

    float maxOffset = csize.width - bounds.size.width;
    if (maxOffset <= 0.0f) return;

    float progress = offset.x / maxOffset;
    if (progress < 0.0f) progress = 0.0f;
    if (progress > 1.0f) progress = 1.0f;

    sProgress = progress;
    applyWallpaperTransform();
}

/* ============================================================
 * HOOK 2: SBUIController -finishLaunching
 * Pre-apply the 1.08x scale at boot so the first scroll
 * doesn't visibly snap from 1.0 → 1.08.
 * ============================================================ */

static void (*orig_finishLaunching)(void *, SEL);

static void hook_finishLaunching(void *self, SEL _cmd) {
    orig_finishLaunching(self, _cmd);

    sProgress = readScrollProgress();
    applyWallpaperTransform();
}

/* ============================================================
 * HOOK 3: SBUIController -activateApplicationAnimated:
 * Stop touching the wallpaper during app-launch animations.
 * ============================================================ */

static void (*orig_activateApp)(void *, SEL, void *);

static void hook_activateApp(void *self, SEL _cmd, void *app) {
    sAppLaunching = YES;
    orig_activateApp(self, _cmd, app);
}

/* ============================================================
 * HOOK 4: SBUIController -restoreIconListAnimated:
 * Re-apply our transform when returning to the home screen.
 * ============================================================ */

static void (*orig_restoreIconList)(void *, SEL, BOOL);

static void hook_restoreIconList(void *self, SEL _cmd, BOOL animated) {
    orig_restoreIconList(self, _cmd, animated);
    sAppLaunching = NO;
    applyWallpaperTransform();
}

/* ============================================================
 * Constructor: install all hooks at load time.
 * ============================================================ */

__attribute__((constructor))
static void init(void) {
    Class iconCls = objc_getClass("SBIconController");
    Class uiCls   = objc_getClass("SBUIController");
    if (!iconCls || !uiCls) return;

    MSHookMessageEx(iconCls,
                    sel_registerName("scrollViewDidScroll:"),
                    (IMP)hook_scrollViewDidScroll,
                    (IMP *)&orig_scrollViewDidScroll);

    MSHookMessageEx(uiCls,
                    sel_registerName("finishLaunching"),
                    (IMP)hook_finishLaunching,
                    (IMP *)&orig_finishLaunching);

    MSHookMessageEx(uiCls,
                    sel_registerName("activateApplicationAnimated:"),
                    (IMP)hook_activateApp,
                    (IMP *)&orig_activateApp);

    MSHookMessageEx(uiCls,
                    sel_registerName("restoreIconListAnimated:"),
                    (IMP)hook_restoreIconList,
                    (IMP *)&orig_restoreIconList);
}
