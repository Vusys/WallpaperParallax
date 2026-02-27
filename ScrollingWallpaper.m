/*
 * ScrollingWallpaper - Parallax wallpaper scrolling for iOS 6
 * Makes the homescreen wallpaper pan with page swipes, like Android.
 *
 * Build (on device):
 *   clang -I/var/sdk/usr/local/include -dynamiclib -lsubstrate -lobjc \
 *     -framework CoreFoundation \
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

static const CGAffineTransform kIdentity = { 1, 0, 0, 1, 0, 0 };

/* --- CoreFoundation types (no headers available) --- */

typedef const void *CFStringRef;
typedef const void *CFNotificationCenterRef;
typedef const void *CFDictionaryRef;
typedef unsigned char Boolean;

#define CFSTR(s) __builtin___CFStringMakeConstantString(s)

extern Boolean CFPreferencesGetAppBooleanValue(
    CFStringRef key, CFStringRef appID, Boolean *keyExistsAndHasValidFormat);

extern CFNotificationCenterRef CFNotificationCenterGetDarwinNotifyCenter(void);

typedef void (*CFNotificationCallback)(
    CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef);

extern void CFNotificationCenterAddObserver(
    CFNotificationCenterRef center, const void *observer,
    CFNotificationCallback callBack, CFStringRef name,
    const void *object, long suspensionBehavior);

/* --- MobileSubstrate --- */

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

/* --- Typed objc_msgSend casts (armv7: stret for structs > 4 bytes) --- */

typedef void *(*msg_id)       (void *, SEL);
typedef BOOL  (*msg_bool)     (void *, SEL);
typedef void  (*msg_void)     (void *, SEL);
typedef void  (*msg_void_2id) (void *, SEL, void *, void *);
typedef void  (*msg_void_dbl) (void *, SEL, double);
typedef void  (*msg_point_s)  (CGPoint *, void *, SEL);
typedef void  (*msg_size_s)   (CGSize *, void *, SEL);
typedef void  (*msg_rect_s)   (CGRect *, void *, SEL);
typedef void  (*msg_setXform) (void *, SEL, CGAffineTransform);

/* --- Constants --- */

static const float  kScale       = 1.08f;
static const double kAnimOut     = 0.15;  /* to identity before app launch */
static const double kAnimIn      = 0.25;  /* to parallax on return */

/* --- State --- */

static float sProgress = 0.0f;
static BOOL  sEnabled  = YES;

/* --- Helpers --- */

static void *getWallpaperView(void) {
    void *ctrl = ((msg_id)objc_msgSend)(
        (void *)objc_getClass("SBUIController"),
        sel_registerName("sharedInstance"));
    return ((msg_id)objc_msgSend)(ctrl, sel_registerName("wallpaperView"));
}

static void beginAnim(double dur) {
    void *uv = (void *)objc_getClass("UIView");
    ((msg_void_2id)objc_msgSend)(uv, sel_registerName("beginAnimations:context:"), 0, 0);
    ((msg_void_dbl)objc_msgSend)(uv, sel_registerName("setAnimationDuration:"), dur);
}

static void commitAnim(void) {
    ((msg_void)objc_msgSend)(
        (void *)objc_getClass("UIView"), sel_registerName("commitAnimations"));
}

static void setXform(void *view, CGAffineTransform t) {
    ((msg_setXform)objc_msgSend)(view, sel_registerName("setTransform:"), t);
}

static void applyParallax(void) {
    void *wp = getWallpaperView();
    if (!wp) return;

    CGRect b;
    ((msg_rect_s)objc_msgSend_stret)(&b, wp, sel_registerName("bounds"));

    float pan   = (kScale - 1.0f) * b.size.width;
    float shift = (0.5f - sProgress) * pan;
    CGAffineTransform t = { kScale, 0, 0, kScale, shift, 0 };
    setXform(wp, t);
}

static float readProgress(void) {
    void *ic = ((msg_id)objc_msgSend)(
        (void *)objc_getClass("SBIconController"),
        sel_registerName("sharedInstance"));
    void *sv = ((msg_id)objc_msgSend)(ic, sel_registerName("scrollView"));
    if (!sv) return 0.0f;

    CGPoint off; ((msg_point_s)objc_msgSend_stret)(&off, sv, sel_registerName("contentOffset"));
    CGSize  cs;  ((msg_size_s)objc_msgSend_stret)(&cs,  sv, sel_registerName("contentSize"));
    CGRect  b;   ((msg_rect_s)objc_msgSend_stret)(&b,   sv, sel_registerName("bounds"));

    float max = cs.width - b.size.width;
    if (max <= 0.0f) return 0.0f;
    float p = off.x / max;
    return p < 0.0f ? 0.0f : p > 1.0f ? 1.0f : p;
}

/* --- Preferences --- */

static void loadPrefs(void) {
    Boolean exists = 0;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("Enabled"),
        CFSTR("com.ios6hacks.scrollingwallpaper"), &exists);
    BOOL was = sEnabled;
    sEnabled = exists ? (BOOL)val : YES;

    if (was && !sEnabled) {
        beginAnim(kAnimIn);
        void *wp = getWallpaperView();
        if (wp) setXform(wp, kIdentity);
        commitAnim();
    } else if (!was && sEnabled) {
        sProgress = readProgress();
        beginAnim(kAnimIn);
        applyParallax();
        commitAnim();
    }
}

static void prefsChanged(CFNotificationCenterRef c, void *obs,
                          CFStringRef name, const void *obj,
                          CFDictionaryRef info) {
    loadPrefs();
}

/* === HOOKS === */

/* 1. SBIconController -scrollViewDidScroll:
 * Only during real user touches (isDragging/isDecelerating). */

static void (*orig_scroll)(void *, SEL, void *);
static void hook_scroll(void *self, SEL _cmd, void *sv) {
    orig_scroll(self, _cmd, sv);
    if (!sEnabled) return;

    BOOL drag = ((msg_bool)objc_msgSend)(sv, sel_registerName("isDragging"));
    BOOL decel = ((msg_bool)objc_msgSend)(sv, sel_registerName("isDecelerating"));
    if (!drag && !decel) return;

    CGPoint off; ((msg_point_s)objc_msgSend_stret)(&off, sv, sel_registerName("contentOffset"));
    CGSize  cs;  ((msg_size_s)objc_msgSend_stret)(&cs,  sv, sel_registerName("contentSize"));
    CGRect  b;   ((msg_rect_s)objc_msgSend_stret)(&b,   sv, sel_registerName("bounds"));

    float max = cs.width - b.size.width;
    if (max <= 0.0f) return;
    float p = off.x / max;
    sProgress = p < 0.0f ? 0.0f : p > 1.0f ? 1.0f : p;
    applyParallax();
}

/* 2. SBUIController -finishLaunching
 * Pre-apply at boot so the first swipe doesn't snap. */

static void (*orig_finish)(void *, SEL);
static void hook_finish(void *self, SEL _cmd) {
    orig_finish(self, _cmd);
    if (!sEnabled) return;
    sProgress = readProgress();
    applyParallax();
}

/* 3. SBUIController -activateApplicationAnimated:
 * Quickly animate wallpaper to identity before iOS does its thing. */

static void (*orig_activate)(void *, SEL, void *);
static void hook_activate(void *self, SEL _cmd, void *app) {
    if (sEnabled) {
        beginAnim(kAnimOut);
        void *wp = getWallpaperView();
        if (wp) setXform(wp, kIdentity);
        commitAnim();
    }
    orig_activate(self, _cmd, app);
}

/* 4. SBUIController -stopRestoringIconList
 * Animate back to parallax when home screen is fully restored. */

static void (*orig_stopRestore)(void *, SEL);
static void hook_stopRestore(void *self, SEL _cmd) {
    orig_stopRestore(self, _cmd);
    if (!sEnabled) return;
    sProgress = readProgress();
    beginAnim(kAnimIn);
    applyParallax();
    commitAnim();
}

/* === Constructor === */

__attribute__((constructor))
static void init(void) {
    Class ic = objc_getClass("SBIconController");
    Class ui = objc_getClass("SBUIController");
    if (!ic || !ui) return;

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        prefsChanged,
        CFSTR("com.ios6hacks.scrollingwallpaper/prefsChanged"),
        NULL, 0);
    loadPrefs();

    MSHookMessageEx(ic, sel_registerName("scrollViewDidScroll:"),
                    (IMP)hook_scroll, (IMP *)&orig_scroll);
    MSHookMessageEx(ui, sel_registerName("finishLaunching"),
                    (IMP)hook_finish, (IMP *)&orig_finish);
    MSHookMessageEx(ui, sel_registerName("activateApplicationAnimated:"),
                    (IMP)hook_activate, (IMP *)&orig_activate);
    MSHookMessageEx(ui, sel_registerName("stopRestoringIconList"),
                    (IMP)hook_stopRestore, (IMP *)&orig_stopRestore);
}
