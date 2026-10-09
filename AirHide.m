// AirHide.dylib
// Kills the full-screen onboarding splash ("Welcome / Cracked by Blatant /
// Instant Certificates / More Apps / CLOSING IN x.xs") the moment it tries to
// show. Everything else keeps running.
//
// Detection (works for UIKit AND SwiftUI splashes):
//   1. WHO drew it: any window / presented VC / full-screen subview created
//      from code living in an injected image (a bare .dylib inside the .app,
//      or any image whose path matches AHBlockNames) is blocked.
//   2. WHAT it is: class / module names matching AHBlockNames.
//   3. TEXT: UILabel text markers (UIKit splashes).
//   4. A 0.1s sweep for 25s after launch / foreground as a safety net.
//
// Config: edit AHBlockNames / AHKeepNames below.
//   AHKeepNames  = image names of YOUR other dylibs that must be allowed to
//                  show full-screen UI (e.g. @"mrzefvam", lowercase).
// Kill switch: NSUserDefaults bool "AirHideOff" = YES disables everything.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <string.h>

#pragma mark - Config

static NSArray<NSString *> *AHBlockNames(void) {
    return @[ @"blatant" ];
}
static NSArray<NSString *> *AHKeepNames(void) {
    return @[ ];
}
static NSArray<NSString *> *AHIgnoreNames(void) {
    static NSArray *a;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        a = @[ @"airhide", @"libswift", @"libc++", @"libobjc", @"ellekit",
               @"substrate", @"substitute", @"libhooker", @"cydia" ];
    });
    return a;
}

static NSString *const kAirHideOff = @"AirHideOff";
static __weak UIWindow *gMain;
static NSInteger gBudget = 0;
static NSTimer *gTimer;

static BOOL AHOff(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kAirHideOff];
}

#pragma mark - Image / name classification

static BOOL AHContainsAny(NSString *s, NSArray<NSString *> *list) {
    for (NSString *n in list) if ([s containsString:n]) return YES;
    return NO;
}

static BOOL AHNameBlocked(NSString *name) {
    if (name.length == 0) return NO;
    return AHContainsAny(name.lowercaseString, AHBlockNames());
}

static BOOL AHPathBlockedUncached(const char *p) {
    if (!p || !strstr(p, ".app/")) return NO;
    NSString *s = [NSString stringWithUTF8String:p].lowercaseString;
    if (!s) return NO;
    if (AHContainsAny(s, AHIgnoreNames())) return NO;
    if (AHContainsAny(s, AHKeepNames())) return NO;
    if (AHContainsAny(s, AHBlockNames())) return YES;
    return [s hasSuffix:@".dylib"]; // bare injected dylib
}

static BOOL AHPathBlocked(const char *p) {
    if (!p) return NO;
    static NSMutableDictionary<NSValue *, NSNumber *> *cache;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ cache = [NSMutableDictionary dictionary]; });
    NSValue *k = [NSValue valueWithPointer:p];
    @synchronized (cache) {
        NSNumber *n = cache[k];
        if (n) return n.boolValue;
        BOOL r = AHPathBlockedUncached(p);
        cache[k] = @(r);
        return r;
    }
}

static BOOL AHClassBlocked(Class c) {
    if (!c) return NO;
    if (AHPathBlocked(class_getImageName(c))) return YES;
    return AHNameBlocked(NSStringFromClass(c));
}

static BOOL AHStackFromBlocked(void) {
    void *fr[48];
    int n = backtrace(fr, 48);
    for (int i = 1; i < n; i++) {
        Dl_info di;
        if (dladdr(fr[i], &di) && AHPathBlocked(di.dli_fname)) return YES;
    }
    return NO;
}

#pragma mark - Text markers (UIKit splashes)

static NSArray<NSString *> *AHMarkers(void) {
    static NSArray *a;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        a = @[ @"instant certificates", @"more apps", @"closing in", @"cracked by" ];
    });
    return a;
}

static NSInteger AHMarkerIndex(NSString *s) {
    if (s.length == 0 || s.length > 80) return -1;
    NSString *l = s.lowercaseString;
    NSArray *m = AHMarkers();
    for (NSUInteger i = 0; i < m.count; i++) {
        if ([l containsString:m[i]]) return (NSInteger)i;
    }
    return -1;
}

static void AHCollect(UIView *v, NSMutableSet *found) {
    if ([v isKindOfClass:UILabel.class]) {
        UILabel *l = (UILabel *)v;
        NSInteger i = AHMarkerIndex(l.text ?: l.attributedText.string);
        if (i >= 0) [found addObject:@(i)];
    } else if ([v isKindOfClass:UIButton.class]) {
        NSInteger i = AHMarkerIndex([(UIButton *)v titleForState:UIControlStateNormal]);
        if (i >= 0) [found addObject:@(i)];
    }
    for (UIView *s in v.subviews) AHCollect(s, found);
}

static UIView *AHFindMarkerView(UIView *v) {
    if ([v isKindOfClass:UILabel.class]) {
        UILabel *l = (UILabel *)v;
        if (AHMarkerIndex(l.text ?: l.attributedText.string) >= 0) return v;
    }
    for (UIView *s in v.subviews) {
        UIView *r = AHFindMarkerView(s);
        if (r) return r;
    }
    return nil;
}

#pragma mark - Window helpers

static UIWindow *AHMainWindow(void) {
    id<UIApplicationDelegate> d = UIApplication.sharedApplication.delegate;
    if ([d respondsToSelector:@selector(window)]) {
        UIWindow *w = [(id)d window];
        if (w) return w;
    }
    return gMain;
}

static BOOL AHIsFull(UIView *v, UIWindow *w) {
    CGRect wb = w.bounds;
    CGRect r = [v convertRect:v.bounds toView:w];
    return r.size.width >= wb.size.width * 0.9 && r.size.height >= wb.size.height * 0.9;
}

static NSArray<UIWindow *> *AHAllWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class]) {
            [out addObjectsFromArray:((UIWindowScene *)sc).windows];
        }
    }
    if (out.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [out addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    }
    return out;
}

#pragma mark - Kill

static void AHKill(UIView *c) {
    UIWindow *w = c.window;
    UIWindow *main = AHMainWindow();
    if (main && c == main.rootViewController.view) return; // never touch the app root
    UIViewController *vc = nil;
    UIResponder *r = c;
    while ((r = r.nextResponder)) {
        if ([r isKindOfClass:UIViewController.class]) { vc = (UIViewController *)r; break; }
    }
    c.hidden = YES;
    c.alpha = 0;
    c.userInteractionEnabled = NO;
    if (vc && vc.view == c && vc.presentingViewController) {
        [vc dismissViewControllerAnimated:NO completion:nil];
    } else if (w && w != main && w.rootViewController.view == c) {
        w.hidden = YES;
    } else {
        [c removeFromSuperview];
    }
}

static UIView *AHFindContainer(UIView *start) {
    UIWindow *w = start.window;
    if (!w) return nil;
    [w layoutIfNeeded];
    UIWindow *main = AHMainWindow();
    UIView *v = start;
    while (v && v != w) {
        if (main && v == main.rootViewController.view) break;
        NSMutableSet *f = [NSMutableSet set];
        AHCollect(v, f);
        if (f.count >= 2 && AHIsFull(v, w)) return v;
        v = v.superview;
    }
    return nil;
}

static BOOL AHTryLabel(UIView *label) {
    if (AHOff()) return NO;
    UIView *c = AHFindContainer(label);
    if (!c) return NO;
    AHKill(c);
    return YES;
}

static void AHCheckLabelAsync(UIView *label) {
    if (AHOff()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (label.window) AHTryLabel(label);
    });
}

static void AHKillIfFullAsync(UIView *v) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = v.window;
        if (!w) return;
        [w layoutIfNeeded];
        if (AHIsFull(v, w)) AHKill(v);
    });
}

#pragma mark - Sweep

static void AHSweepView(UIView *v, UIWindow *w) {
    if (AHClassBlocked(object_getClass(v)) && AHIsFull(v, w)) { AHKill(v); return; }
    for (UIView *s in [v.subviews copy]) AHSweepView(s, w);
}

static void AHSweepVC(UIViewController *vc) {
    if (!vc) return;
    UIWindow *main = AHMainWindow();
    if (AHClassBlocked(object_getClass(vc)) && vc.view != main.rootViewController.view) {
        if (vc.presentingViewController) {
            [vc dismissViewControllerAnimated:NO completion:nil];
        } else if (vc.parentViewController) {
            vc.view.hidden = YES;
            vc.view.alpha = 0;
            vc.view.userInteractionEnabled = NO;
            [vc.view removeFromSuperview];
        }
        return;
    }
    for (UIViewController *c in [vc.childViewControllers copy]) AHSweepVC(c);
    AHSweepVC(vc.presentedViewController);
}

static void AHSweep(void) {
    if (AHOff()) return;
    UIWindow *main = AHMainWindow();
    for (UIWindow *w in AHAllWindows()) {
        if (w != main && (AHClassBlocked(object_getClass(w)) ||
                          AHClassBlocked(object_getClass(w.rootViewController)))) {
            w.hidden = YES;
            continue;
        }
        AHSweepVC(w.rootViewController);
        AHSweepView(w, w);
        UIView *hit = AHFindMarkerView(w);
        if (hit) AHTryLabel(hit);
    }
}

static void AHStartTimer(void) {
    gBudget = 250; // 25s @ 0.1s
    if (gTimer) return;
    gTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        AHSweep();
        if (--gBudget <= 0) { [t invalidate]; gTimer = nil; }
    }];
    [NSRunLoop.mainRunLoop addTimer:gTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - Swizzles

static void AHSwz(Class c, SEL o, SEL n) {
    Method om = class_getInstanceMethod(c, o);
    Method nm = class_getInstanceMethod(c, n);
    if (!om || !nm) return;
    if (class_addMethod(c, o, method_getImplementation(nm), method_getTypeEncoding(nm))) {
        class_replaceMethod(c, n, method_getImplementation(om), method_getTypeEncoding(om));
    } else {
        method_exchangeImplementations(om, nm);
    }
}

static void AHAfterAdd(UIView *parent, UIView *child) {
    if (AHOff() || !child) return;
    BOOL inspect = [parent isKindOfClass:UIWindow.class]
                || (gMain && parent == gMain.rootViewController.view)
                || AHClassBlocked(object_getClass(child));
    if (!inspect) return;
    if (AHClassBlocked(object_getClass(child)) || AHStackFromBlocked()) {
        AHKillIfFullAsync(child);
    }
}

@interface UIView (AirHide)
@end
@implementation UIView (AirHide)
- (void)ah_addSubview:(UIView *)v {
    [self ah_addSubview:v];
    AHAfterAdd(self, v);
}
- (void)ah_insertSubview:(UIView *)v atIndex:(NSInteger)i {
    [self ah_insertSubview:v atIndex:i];
    AHAfterAdd(self, v);
}
- (void)ah_insertSubview:(UIView *)v aboveSubview:(UIView *)s {
    [self ah_insertSubview:v aboveSubview:s];
    AHAfterAdd(self, v);
}
@end

@interface UILabel (AirHide)
@end
@implementation UILabel (AirHide)
- (void)ah_setText:(NSString *)t {
    [self ah_setText:t];
    if (self.window && AHMarkerIndex(t) >= 0) AHCheckLabelAsync(self);
}
- (void)ah_setAttributedText:(NSAttributedString *)t {
    [self ah_setAttributedText:t];
    if (self.window && AHMarkerIndex(t.string) >= 0) AHCheckLabelAsync(self);
}
- (void)ah_didMoveToWindow {
    [self ah_didMoveToWindow];
    if (self.window && AHMarkerIndex(self.text ?: self.attributedText.string) >= 0) AHCheckLabelAsync(self);
}
@end

@interface UIWindow (AirHide)
@end
@implementation UIWindow (AirHide)
- (void)ah_makeKeyAndVisible {
    if (AHOff()) { [self ah_makeKeyAndVisible]; return; }
    BOOL blocked = AHClassBlocked(object_getClass(self)) || AHStackFromBlocked();
    if (!gMain && !blocked) gMain = self;
    if (blocked && self != AHMainWindow()) {
        self.hidden = YES;
        return;
    }
    [self ah_makeKeyAndVisible];
}
- (void)ah_setHidden:(BOOL)h {
    if (!h && !AHOff() && self != AHMainWindow() && gMain &&
        (AHClassBlocked(object_getClass(self)) || AHStackFromBlocked())) {
        h = YES;
    }
    [self ah_setHidden:h];
}
@end

@interface UIViewController (AirHide)
@end
@implementation UIViewController (AirHide)
- (void)ah_presentViewController:(UIViewController *)vc animated:(BOOL)a completion:(void (^)(void))c {
    if (!AHOff() && vc &&
        ![vc isKindOfClass:UIAlertController.class] &&
        ![vc isKindOfClass:UIActivityViewController.class] &&
        (AHClassBlocked(object_getClass(vc)) || AHStackFromBlocked())) {
        if (c) dispatch_async(dispatch_get_main_queue(), c);
        return;
    }
    [self ah_presentViewController:vc animated:a completion:c];
}
@end

#pragma mark - Entry

__attribute__((constructor))
static void AirHideInit(void) {
    AHSwz(UIView.class, @selector(addSubview:), @selector(ah_addSubview:));
    AHSwz(UIView.class, @selector(insertSubview:atIndex:), @selector(ah_insertSubview:atIndex:));
    AHSwz(UIView.class, @selector(insertSubview:aboveSubview:), @selector(ah_insertSubview:aboveSubview:));
    AHSwz(UILabel.class, @selector(setText:), @selector(ah_setText:));
    AHSwz(UILabel.class, @selector(setAttributedText:), @selector(ah_setAttributedText:));
    AHSwz(UILabel.class, @selector(didMoveToWindow), @selector(ah_didMoveToWindow));
    AHSwz(UIWindow.class, @selector(makeKeyAndVisible), @selector(ah_makeKeyAndVisible));
    AHSwz(UIWindow.class, @selector(setHidden:), @selector(ah_setHidden:));
    AHSwz(UIViewController.class,
          @selector(presentViewController:animated:completion:),
          @selector(ah_presentViewController:animated:completion:));

    dispatch_async(dispatch_get_main_queue(), ^{ AHStartTimer(); });
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { AHStartTimer(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { AHStartTimer(); }];
}
