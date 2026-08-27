/*
 * Wallpaper Parallax - Parallax wallpaper scrolling for iOS 6
 * Makes the homescreen wallpaper pan with page swipes, like Android.
 *
 * v0.3 architecture change: instead of transforming SBUIController's own
 * `wallpaperView` (fighting iOS's own zoom/reset animations on that exact
 * view for every app open/close -- the source of the v0.2 "visible pop"
 * bug), this version allocates a SECOND, independent SBWallpaperView
 * instance that we own outright, inserts it as a sibling of the stock one,
 * and makes the stock one fully transparent (alpha 0, left otherwise
 * untouched -- still alive, still receiving iOS's own real zoom/orientation/
 * wallpaper-change updates, just invisible).
 *
 * Because iOS's own transition code only ever touches the *stock* instance
 * (our own is invisible to it), there is nothing left to "fight" -- our own
 * view's transform is entirely ours to drive. The app-open/close zoom
 * flourish is applied directly (a confirmed, consistent 1.4x on open, back
 * to rest on close) from -activateApplicationAnimated:/
 * -restoreIconListAnimated:...:, the real app-lifecycle methods -- NOT from
 * -zoomWallpaper:delay:duration:, which this device's Barrel install
 * (com.hackyouriphone.barrel) also calls itself for its own icon-depth
 * effect, confirmed by testing to fire in a continuous open/close
 * oscillation with no user interaction at all. See the SBUIController hook
 * comments below for the full history of what didn't work first.
 *
 * Confirmed technique: [[objc_getClass("SBWallpaperView") alloc]
 * initWithOrientation:variant:] auto-populates with the real current
 * wallpaper image with no manual image copying -- this exact pattern is
 * already proven working in the sibling osexperience project's
 * OSDesktopPane on this same device/build (iOS 6 has no SBWallpaperController,
 * so SBWallpaperView is built directly). variant 0 = home screen (matches
 * osexperience's usage for a home-screen-styled pane); not otherwise
 * documented -- confirm the on-screen image is the home wallpaper, not the
 * lock screen one, when testing.
 *
 * Build (on-device theos, see project CLAUDE.md / SETUP.md):
 *   cd /var/root/WallpaperParallax
 *   export THEOS=/var/theos && export PATH=$THEOS/bin:$PATH
 *   make package
 *   dpkg -i --force-depends debs/packages/com.vusys.wallpaperparallax_*.deb
 *   sbreload
 */

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

#pragma mark - Private API surface

@interface SBWallpaperView : UIImageView
- (id)initWithOrientation:(int)orientation variant:(int)variant;
@property (assign, nonatomic) int orientation;
@end

@interface SBIconController : NSObject
+ (id)sharedInstance;
- (UIScrollView *)scrollView;
@end

@interface SBUIController : NSObject
+ (id)sharedInstance;
- (UIView *)wallpaperView;
- (void)finishLaunching;
- (void)activateApplicationAnimated:(id)application;
- (void)restoreIconListAnimated:(char)animated delay:(double)delay animateWallpaper:(char)animateWallpaper keepSwitcher:(char)keepSwitcher;
- (void)restoreIconListAnimated:(char)animated animateWallpaper:(char)animateWallpaper;
- (void)restoreIconListAnimated:(char)animated animateWallpaper:(char)animateWallpaper keepSwitcher:(char)keepSwitcher;
@end

/* REMOVED: a UIGetScreenImage()-based debug screenshot helper lived here
 * briefly to get ground truth on what was actually rendering. Confirmed by
 * testing -- exactly as the sibling untitled-ios6-splitscreen-tweak
 * project's notes warned ("UIGetScreenImage() is what wedged the main
 * thread") -- it froze SpringBoard's main thread on this device/build
 * (CPU climbing, unresponsive, required killall -9 + sbreload to recover,
 * tripped Safe Mode). Do not reach for UIGetScreenImage() again on the main
 * thread here; that project's notes speculate it might need to run off the
 * main thread instead, not investigated further. */

/* Heavy trajectory/state logging (heartbeat, scroll, zoom, re-attach) is
 * gated behind this build flag rather than deleted -- this device's
 * environment is fragile enough (Barrel churn etc., see project memory)
 * that it's routinely needed again. Default is set by the Makefile (DEBUG=1
 * there); `make DEBUG=0` builds a quiet release with these compiled out
 * entirely, not just silenced at runtime. */
#ifndef SWP_DEBUG_LOG
#define SWP_DEBUG_LOG 1
#endif

#if SWP_DEBUG_LOG
#define SWPLog(...) NSLog(__VA_ARGS__)
#else
#define SWPLog(...) do {} while (0)
#endif

#pragma mark - Constants

static const float kMinScale        = 1.00f; /* strength=0.0 -- no effect */
/* strength=1.0 -- strongest effect. The old top end (1.20, i.e. a 0.20
 * overhang) felt too weak in practice -- confirmed by testing, dragging the
 * slider all the way to the right still only read as roughly 75% of a
 * proper Android-style parallax. Rescaled so that old max now sits at the
 * 75% mark of the new range instead of at 100%: 0.20 / 0.75 = 0.2667
 * overhang -> 1.2667 scale at strength=1.0, i.e. every setting hits
 * noticeably harder than before. */
static const float kMaxScale        = 1.2667f;
static const float kDefaultStrength = 0.4f;  /* -> ~1.107 scale under the rescaled range above */
static const float kOpenZoomFactor  = 1.4f;  /* iOS's own zoom-in scale on app open, confirmed exact and repeatable */
static const double kZoomAnimDuration = 0.5; /* matches the real duration observed from genuine iOS zoom calls */

#define PREFS_ID CFSTR("com.vusys.wallpaperparallax")

#pragma mark - State

static float sProgress = 0.0f;
static BOOL  sEnabled  = YES;
static float sScale    = 1.107f; /* "Strength" pref -- see loadPrefs */


/* Our own, independently-alloc'd wallpaper view. Created lazily on first
 * -finishLaunching (see hazard note on loadPrefs below for why not sooner). */
static SBWallpaperView *sOurWallpaperView = nil;

#pragma mark - Helpers

static UIView *stockWallpaperView(void) {
    id ui = [objc_getClass("SBUIController") sharedInstance];
    return [ui wallpaperView];
}

/* Scale and shift are NOT independent -- the shift magnitude a given scale
 * can safely support (without exposing an edge) is derived directly from
 * that scale's overhang, (scale-1)*width. Composing a zoom multiplier onto
 * an already-computed transform's scale WITHOUT recomputing shift for the
 * new effective scale breaks that relationship -- confirmed by testing:
 * app-close, mixed with the zoom-delta hack below, showed a gap that got
 * wider the further from center the current page was, exactly what you'd
 * see from scale and shift drifting out of proportion. Always go through
 * this helper with the actual effective scale in play, never patch a
 * transform's .a/.d after the fact. */
static CGAffineTransform parallaxTransformWithScale(UIView *wp, float scale) {
    if (scale < kMinScale) scale = kMinScale; /* never shrink below full screen coverage */
    CGRect b = wp.bounds;
    float pan   = (scale - 1.0f) * b.size.width;
    float shift = (0.5f - sProgress) * pan;
    return CGAffineTransformMake(scale, 0, 0, scale, shift, 0);
}

static CGAffineTransform parallaxTransform(UIView *wp) {
    return parallaxTransformWithScale(wp, sScale);
}

/* Inserts `ours` directly above `stock` in stock's current superview and
 * hides stock. Shared by initial creation and by re-attachment after an
 * eviction (see ensureOurWallpaperView) -- both need the exact same
 * placement logic, just against a possibly-different `stock`/superview
 * instance the second time around. */
static void attachOursNextToStock(SBWallpaperView *ours, UIView *stock) {
    /* .frame is undefined/unreliable whenever .transform isn't identity
     * (Apple's own documented behavior, not a guess) -- and ours almost
     * always HAS a non-identity transform by the time re-attachment runs
     * (it's mid-pan any time except sProgress==0.5 exactly). First fix
     * attempt: reset .transform to identity, set .frame, then have the
     * caller re-derive the correct transform fresh afterward. That solved
     * the geometry corruption but introduced a NEW bug, confirmed by
     * testing: eviction-healing fires very frequently (Barrel's own churn),
     * and its instant, non-animated re-derivation could win a race against
     * our explicit open/close zoom hooks -- snapping .transform to the
     * correct resting value a moment before applyCloseZoom's own animated
     * transition ran, leaving nothing left to visibly animate ("close
     * doesn't animate" symptom).
     *
     * Root fix: .bounds + .center are ALWAYS well-defined regardless of
     * the view's current .transform (transform is applied on top of them
     * at render time, doesn't corrupt them) -- unlike .frame, which is
     * only meaningful when transform is identity. Repositioning through
     * these means re-attachment never needs to touch .transform at all
     * when nothing about the pan/zoom state actually changed: whatever was
     * there before eviction is exactly what's there after. No identity
     * reset, no re-derivation, no race. */
    ours.bounds = CGRectMake(0, 0, stock.frame.size.width, stock.frame.size.height);
    ours.center = CGPointMake(CGRectGetMidX(stock.frame), CGRectGetMidY(stock.frame));
    ours.autoresizingMask = stock.autoresizingMask;

    /* REVERTED: briefly tried insertSubview:atIndex:stockIndex here (taking
     * over stock's exact z-slot) to fix a cosmetic complaint -- a
     * status-bar/dock contrast vignette ended up sandwiched between stock
     * and ours instead of above both. That "fix" caused a much worse
     * regression, confirmed by testing: whatever that vignette view really
     * is apparently isn't a thin gradient sliver, and putting it above ours
     * instead of below it blocked our entire wallpaper from view (reported
     * as "all black" -- our own state logging showed correct alpha/hidden/
     * window/transform the whole time, so this was a compositing/z-order
     * problem, not a state one). Back to plain aboveSubview:, which puts
     * ours on top of stock and everything stock was already below,
     * including that vignette -- the cosmetic complaint (vignette effect
     * covered by our opaque wallpaper) is a real but much smaller issue
     * than "nothing renders at all". */
    [stock.superview insertSubview:ours aboveSubview:stock];
    stock.alpha = 0.0f;
}

static SBWallpaperView *createOurWallpaperView(void) {
    UIView *stock = stockWallpaperView();
    if (!stock || !stock.superview) return nil;

    int orientation = 0;
    if ([stock isKindOfClass:objc_getClass("SBWallpaperView")]) {
        orientation = ((SBWallpaperView *)stock).orientation;
    }

    SBWallpaperView *ours = [[objc_getClass("SBWallpaperView") alloc]
        initWithOrientation:orientation variant:0];
    attachOursNextToStock(ours, stock);

    SWPLog(@"[WallpaperParallax] created own SBWallpaperView %@ frame=%@ orientation=%d "
          @"image=%@ (stock=%@ stock.image=%@)",
          ours, NSStringFromCGRect(ours.frame), orientation, ours.image,
          stock, ((UIImageView *)stock).image);
    return ours;
}

/* Lazily (re)tries creation, AND heals eviction. Two distinct problems
 * confirmed by testing on a real device:
 *  1. At -finishLaunching time the stock wallpaper view exists but is NOT
 *     YET in the view hierarchy (stock.superview nil) -- our first creation
 *     attempt there silently no-ops.
 *  2. Some time after successful creation -- reproducibly across a
 *     lock/unlock cycle -- sOurWallpaperView.superview goes back to nil
 *     even though the object itself is still alive (confirmed via logging
 *     every scroll event: "ours.superview=(null)" on every one, right when
 *     panning visibly stopped working). Whatever SpringBoard/the lock
 *     screen does to the wallpaper hierarchy across that transition evicts
 *     our injected sibling -- it doesn't know about it and isn't
 *     responsible for preserving it. Since we don't know the exact
 *     mechanism (no live debugger on this device, see project CLAUDE.md),
 *     the robust fix is to just re-attach whenever we notice we've been
 *     evicted, rather than chase the exact SpringBoard call responsible.
 * Called from every hook that's about to rely on sOurWallpaperView, so
 * healing happens on the very next scroll/zoom event after an eviction. */
static void ensureOurWallpaperView(void) {
    if (!sEnabled) return;

    if (!sOurWallpaperView) {
        sOurWallpaperView = createOurWallpaperView();
        return;
    }

    /* Re-assert stock's alpha unconditionally, every call, even when we're
     * still attached -- confirmed by testing that Barrel resets it back to
     * visible (1.0) WITHOUT necessarily evicting our sibling at the same
     * time (its own animation cycle touches stock independently of whether
     * our view is still there). Re-asserting only from the eviction-repair
     * path below missed that case entirely: superview stayed non-nil, so
     * the code never even looked at stock's alpha again, and the (static,
     * unpanned) stock wallpaper stayed visible on top, masking our panning
     * view underneath -- which is exactly what looked like "no panning"
     * even though our own transform math was completely correct. */
    UIView *stock = stockWallpaperView();
    if (stock) stock.alpha = 0.0f;

    /* .window, not just .superview: a non-nil superview only proves we're
     * parented inside SOME view, not that the chain still reaches the real
     * on-screen UIWindow. If Barrel swaps in a whole new container and
     * reparents stock into it, our sibling could be left correctly parented
     * inside the OLD, now fully-detached container -- .superview would
     * still read non-nil and this function would wrongly conclude nothing
     * needs fixing, while nothing we do renders at all. .window is nil the
     * instant any ancestor drops off the live hierarchy, so it's the
     * correct liveness check here. */
    if (sOurWallpaperView.window) return; /* actually on-screen -- nothing else to do */

    if (!stock || !stock.superview) return; /* heal on the next opportunity instead */

    SWPLog(@"[WallpaperParallax] re-attaching own view %@ to %@ (was evicted or orphaned, "
          @"had window=%@, stock=%@)",
          sOurWallpaperView, stock.superview, sOurWallpaperView.window, stock);
    /* attachOursNextToStock repositions via .bounds/.center now, not
     * .frame -- it no longer touches .transform at all, so whatever pan/
     * zoom state was in effect before eviction carries through re-
     * attachment completely untouched. No re-derivation needed here
     * anymore (see attachOursNextToStock's own comment for why the old
     * "reset then re-derive" approach raced with and defeated the explicit
     * open/close zoom hooks). */
    attachOursNextToStock(sOurWallpaperView, stock);
}

/*
 * Two distinct problems this permanent heartbeat covers, both confirmed by
 * testing on a real device:
 *  1. At -finishLaunching time, stock.superview is still nil (our first
 *     creation attempt there silently no-ops), and it's not reliably safe
 *     to assume some other hook fires soon enough to create it either.
 *  2. This device also has Barrel (com.hackyouriphone.barrel,
 *     threedeeboard.dylib) installed, which -- confirmed via `strings` on
 *     its dylib -- itself manages SBUIController's wallpaper-adjacent view
 *     hierarchy for its own icon-depth effect (_wallpaperRelativeFrame,
 *     _wallpaperRelativeIconCenterForIconView:, plus addSubview:/
 *     removeFromSuperview/subviews/superview). It doesn't know about our
 *     injected sibling and its own subview bookkeeping periodically prunes
 *     it -- confirmed by testing: ours.superview logged nil repeatedly
 *     during plain scrolling, no lock/unlock or app transition involved.
 * Rather than chase Barrel's exact eviction trigger, this timer just keeps
 * checking and re-attaches within one tick whenever we notice we're gone.
 * Runs forever (not one-shot) since eviction can recur at any time, not
 * just at boot. NSTimer needs an Objective-C target/selector, hence this
 * tiny helper class rather than a bare C function.
 */
@interface SWPHeartbeatHelper : NSObject
@end
@implementation SWPHeartbeatHelper
- (void)tick:(NSTimer *)t {
    /* Unconditional trajectory log -- diagnosing a reported eviction/reheal
     * loop stuck at a fixed 1.68 scale (our own open-zoom value) that
     * doesn't seem to be un-sticking on its own. Every tick, not just when
     * ensureOurWallpaperView notices something wrong, to see the actual
     * before/after sequence rather than just eviction-detection snapshots. */
    CGAffineTransform before = sOurWallpaperView ? sOurWallpaperView.transform : CGAffineTransformIdentity;
    UIWindow *windowBefore = sOurWallpaperView.window;
    ensureOurWallpaperView();
    CGAffineTransform after = sOurWallpaperView ? sOurWallpaperView.transform : CGAffineTransformIdentity;
    /* Only actually consumed inside SWPLog below, which compiles away
     * entirely under SWP_LOG=0 -- these casts keep that build warning-free
     * (-Wunused-variable) without gating the trajectory-capture code itself
     * behind #if, so both builds compute the exact same before/after values
     * regardless of whether they end up logged. */
    (void)before; (void)windowBefore; (void)after;
    SWPLog(@"[WallpaperParallax] heartbeat before=%@ windowBefore=%@ after=%@ sScale=%.3f sProgress=%.3f",
          NSStringFromCGAffineTransform(before), windowBefore,
          NSStringFromCGAffineTransform(after), sScale, sProgress);
}
@end

static void startWallpaperViewHeartbeat(void) {
    SWPHeartbeatHelper *helper = [SWPHeartbeatHelper new];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:helper selector:@selector(tick:)
                                    userInfo:nil repeats:YES];
}

static void applyParallax(void) {
    ensureOurWallpaperView();
    if (!sOurWallpaperView) return;
    sOurWallpaperView.transform = parallaxTransform(sOurWallpaperView);
}

static float readProgress(void) {
    UIScrollView *sv = [[objc_getClass("SBIconController") sharedInstance] scrollView];
    if (!sv) return 0.0f;

    float max = sv.contentSize.width - sv.bounds.size.width;
    if (max <= 0.0f) return 0.0f;
    float p = sv.contentOffset.x / max;
    return p < 0.0f ? 0.0f : p > 1.0f ? 1.0f : p;
}

/* Toggle which view is visible. Cheap and safe in both directions since we
 * never mutate the stock view beyond its alpha -- disabling the tweak is
 * just "show stock again", nothing to undo on the transform side. */
static void setVisualEnabled(BOOL enabled) {
    if (enabled) ensureOurWallpaperView();
    UIView *stock = stockWallpaperView();
    SWPLog(@"[WallpaperParallax] setVisualEnabled:%d ours=%@ stock=%@ scale=%.3f",
          enabled, sOurWallpaperView, stock, sScale);
    if (enabled) {
        sOurWallpaperView.alpha = 1.0f;
        stock.alpha = 0.0f;
        sProgress = readProgress();
        applyParallax();
    } else {
        sOurWallpaperView.alpha = 0.0f;
        stock.alpha = 1.0f;
    }
}

#pragma mark - Preferences

static void loadPrefs(void) {
    CFPreferencesAppSynchronize(PREFS_ID);

    Boolean exists = 0;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_ID, &exists);
    BOOL was = sEnabled;
    sEnabled = exists ? (BOOL)val : YES;

    /* "Strength" is stored as a plain 0.0-1.0 fraction, not an absolute
     * scale -- confirmed by testing that the slider's minimumValue/
     * maximumValue specifier keys aren't actually honored by the control on
     * this PreferenceLoader version, so remapping into [kMinScale,
     * kMaxScale] happens here instead of trusting the plist. */
    CFPropertyListRef strength = CFPreferencesCopyAppValue(CFSTR("Strength"), PREFS_ID);
    double fraction = kDefaultStrength;
    if (strength) {
        double d;
        if (CFNumberGetValue((CFNumberRef)strength, kCFNumberDoubleType, &d)) {
            fraction = d < 0.0 ? 0.0 : d > 1.0 ? 1.0 : d;
        }
        CFRelease(strength);
    }
    sScale = kMinScale + (float)fraction * (kMaxScale - kMinScale);

    if (was != sEnabled || sOurWallpaperView == nil) {
        setVisualEnabled(sEnabled);
    } else if (sEnabled) {
        applyParallax();
    }
}

/* The Strength slider posts this Darwin notification continuously while
 * being dragged (many times/sec, not just on release); rate-limit to at
 * most 10 actual reloads/sec so a fast drag doesn't flood cfprefsd IPC --
 * see v0.2 comment history for the full story. */
static double sLastPrefsReload = 0.0;

static void prefsChanged(CFNotificationCenterRef c, void *obs,
                          CFStringRef name, const void *obj,
                          CFDictionaryRef info) {
    double now = CFAbsoluteTimeGetCurrent();
    if (now - sLastPrefsReload < 0.1) return;
    sLastPrefsReload = now;
    loadPrefs();
}

#pragma mark - Hooks

%hook SBIconController

/* Only during real user touches (isDragging/isDecelerating), same as v0.2. */
- (void)scrollViewDidScroll:(UIScrollView *)sv {
    %orig;
    if (!sEnabled) return;
    ensureOurWallpaperView();

    static double sLastScrollLog = 0.0;
    double now = CFAbsoluteTimeGetCurrent();
    BOOL shouldLog = (now - sLastScrollLog > 0.5);
    if (shouldLog) sLastScrollLog = now;

    if (!sOurWallpaperView) {
        if (shouldLog) SWPLog(@"[WallpaperParallax] scrollViewDidScroll: no view yet");
        return;
    }
    if (!sv.isDragging && !sv.isDecelerating) {
        if (shouldLog) SWPLog(@"[WallpaperParallax] scrollViewDidScroll: skip (not dragging/decelerating)");
        return;
    }

    float max = sv.contentSize.width - sv.bounds.size.width;
    if (max <= 0.0f) return;
    float p = sv.contentOffset.x / max;
    sProgress = p < 0.0f ? 0.0f : p > 1.0f ? 1.0f : p;
    applyParallax();
    if (shouldLog) {
        SWPLog(@"[WallpaperParallax] scroll rawP=%.3f p(clamped)=%.3f offset=%@ contentSize=%@ "
              @"bounds=%@ transform=%@",
              p, sProgress, NSStringFromCGPoint(sv.contentOffset),
              NSStringFromCGSize(sv.contentSize), NSStringFromCGRect(sv.bounds),
              NSStringFromCGAffineTransform(sOurWallpaperView.transform));
    }
}

%end

%hook SBUIController

/* First real read of preferences (see hazard note in %ctor below for why
 * not sooner), and where our own wallpaper view first gets created. */
- (void)finishLaunching {
    %orig;
    loadPrefs();
    startWallpaperViewHeartbeat();
}

/* v1/v2/v3 (all abandoned): drove the zoom flourish off
 * -zoomWallpaper:delay:duration:, first by reading stock.transform.a
 * (contaminated by Barrel's own writes to the same view), then by a
 * same-call before/after snapshot (still unreliable on the close side),
 * then by applying a hardcoded 1.4x directly to sidestep reading stock at
 * all. None of these actually fixed it, because the real problem was never
 * the *value* -- it was the *hook*. Confirmed by testing (full before/after
 * trace logging): -zoomWallpaper:delay:duration: fires in a continuous
 * zoomIn=1/zoomIn=0 oscillation roughly every 1-2 seconds on this device,
 * with no user interaction at all. Barrel's whole purpose is "3D and other
 * page transition effects" -- it almost certainly calls this same private
 * SpringBoard method itself to drive its own icon-depth animation, making
 * it fundamentally unable to tell a real app launch from Barrel's own
 * cosmetic use of the same call.
 *
 * v4 (this version): hook the real app-lifecycle methods instead --
 * -activateApplicationAnimated: (an app is actually being brought to the
 * foreground) and -restoreIconListAnimated:...: (the icon list, i.e. home
 * screen, is actually being restored). These carry real side effects
 * (foregrounding/backgrounding a genuine SBApplication) that a cosmetic
 * page-transition tweak has no reason to trigger just for a visual effect,
 * unlike zoomWallpaper which is apparently fair game for exactly that. */
static void applyOpenZoom(void) {
    if (!sEnabled) return;
    ensureOurWallpaperView();
    if (!sOurWallpaperView) return;
    sProgress = readProgress(); /* may have changed while backgrounded, e.g. a page-jump from Spotlight */
    CGAffineTransform target = parallaxTransformWithScale(sOurWallpaperView, sScale * kOpenZoomFactor);
    SWPLog(@"[WallpaperParallax] applyOpenZoom before=%@ target=%@",
          NSStringFromCGAffineTransform(sOurWallpaperView.transform), NSStringFromCGAffineTransform(target));
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:kZoomAnimDuration];
    sOurWallpaperView.transform = target;
    [UIView commitAnimations];
}

static void applyCloseZoom(void) {
    if (!sEnabled) return;
    ensureOurWallpaperView();
    if (!sOurWallpaperView) return;
    CGAffineTransform target = parallaxTransform(sOurWallpaperView); /* sScale, no extra zoom */
    SWPLog(@"[WallpaperParallax] applyCloseZoom before=%@ target=%@",
          NSStringFromCGAffineTransform(sOurWallpaperView.transform), NSStringFromCGAffineTransform(target));
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:kZoomAnimDuration];
    sOurWallpaperView.transform = target;
    [UIView commitAnimations];
}

- (void)activateApplicationAnimated:(id)application {
    %orig;
    applyOpenZoom();
}

/* All three restoreIconListAnimated: overloads hooked since it's not
 * confirmed which one(s) fire for a plain Home-button close on this build
 * -- harmless if more than one fires for the same real transition, since
 * applyCloseZoom() just re-targets the same correct resting transform each
 * time. */
- (void)restoreIconListAnimated:(char)animated delay:(double)delay animateWallpaper:(char)animateWallpaper keepSwitcher:(char)keepSwitcher {
    %orig;
    applyCloseZoom();
}

- (void)restoreIconListAnimated:(char)animated animateWallpaper:(char)animateWallpaper {
    %orig;
    applyCloseZoom();
}

- (void)restoreIconListAnimated:(char)animated animateWallpaper:(char)animateWallpaper keepSwitcher:(char)keepSwitcher {
    %orig;
    applyCloseZoom();
}

%end

%ctor {
    %init;

    /* NOT calling loadPrefs() here -- confirmed by testing in v0.2 (three
     * real SpringBoard hangs): CFPreferencesCopyAppValue hangs forever
     * called this early, inside a MobileSubstrate constructor during
     * dlopen, before SpringBoard's own run loop is pumping.
     * CFPreferencesAppSynchronize/CFPreferencesGetAppBooleanValue tolerate
     * it, but CopyAppValue's reply needs a live run loop. First real prefs
     * read happens in %hook SBUIController -finishLaunching instead. */
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        prefsChanged,
        CFSTR("com.vusys.wallpaperparallax/prefsChanged"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
