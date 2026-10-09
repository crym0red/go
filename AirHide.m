// AirHide.dylib
// Standalone overlay-killer. Matches the splash by what is on screen, so it works on any dylib/app.
// The onboarding splash ("Welcome" / Instant Certificates / More Apps /
// CLOSING IN x.xs) is killed the moment it appears. No flash, no countdown.
//
// How it finds the splash without touching Dozy's code:
//   - hooks UILabel (setText / setAttributedText / didMoveToWindow) and watches
//     for the splash strings
//   - once 2+ of the strings live under one full-screen container, that
//     container is hidden / dismissed / its window is hidden
//   - a 0.1s sweep timer runs for 25s after launch and after every
//     foreground as a safety net
//
// Kill switch: NSUserDefaults bool "AirHideOff" = YES disables everything.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kAirHideOff = @"AirHideOff";
static __weak UIWindow *gMain;
static NSInteger gBudget = 0;
static NSTimer *gTimer;

#pragma mark - Markers

static NSArray<NSString *> *AHMarkers(void) {
    static NSArray *a;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        a = @[@"instant certificates", @"more apps", @"closing in"];
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
        NSString *t = l.text ?: l.attributedText.string;
        NSInteger i = AHMarkerIndex(t);
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

static UIView *AHFindContainer(UIView *start) {
    UIWindow *w = start.window;
    if (!w) return nil;
    [w layoutIfNeeded];
    UIWindow *main = AHMainWindow();
    UIView *v = start;
    while (v && v != w) {
        if (main && v == main.rootViewController.view) break; // never touch the app root
        NSMutableSet *f = [NSMutableSet set];
        AHCollect(v, f);
        if (f.count >= 2 && AHIsFull(v, w)) return v;
        v = v.superview;
    }
    return nil;
}

static void AHKill(UIView *c) {
    UIWindow *w = c.window;
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
    } else if (w && w != AHMainWindow() && w.rootViewController.view == c) {
        w.hidden = YES;
    } else {
        [c removeFromSuperview];
    }
}

static BOOL AHTry(UIView *label) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kAirHideOff]) return NO;
    UIView *c = AHFindContainer(label);
    if (!c) return NO;
    AHKill(c);
    return YES;
}

static void AHCheckAsync(UIView *label) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kAirHideOff]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (label.window) AHTry(label);
    });
}

static void AHSweep(void) {
    for (UIWindow *w in AHAllWindows()) {
        UIView *hit = AHFindMarkerView(w);
        if (hit) AHTry(hit);
    }
}

static void AHStartTimer(void) {
    gBudget = 250; // 25s @ 0.1s
    if (gTimer) return;
    gTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
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

@interface UILabel (AirHide)
@end
@implementation UILabel (AirHide)
- (void)ah_setText:(NSString *)t {
    [self ah_setText:t];
    if (self.window && AHMarkerIndex(t) >= 0) AHCheckAsync(self);
}
- (void)ah_setAttributedText:(NSAttributedString *)t {
    [self ah_setAttributedText:t];
    if (self.window && AHMarkerIndex(t.string) >= 0) AHCheckAsync(self);
}
- (void)ah_didMoveToWindow {
    [self ah_didMoveToWindow];
    if (self.window && AHMarkerIndex(self.text ?: self.attributedText.string) >= 0) AHCheckAsync(self);
}
@end

@interface UIWindow (AirHide)
@end
@implementation UIWindow (AirHide)
- (void)ah_makeKeyAndVisible {
    if (!gMain) gMain = self;
    [self ah_makeKeyAndVisible];
}
@end

#pragma mark - Entry

__attribute__((constructor))
static void AirHideInit(void) {
    AHSwz(UILabel.class, @selector(setText:), @selector(ah_setText:));
    AHSwz(UILabel.class, @selector(setAttributedText:), @selector(ah_setAttributedText:));
    AHSwz(UILabel.class, @selector(didMoveToWindow), @selector(ah_didMoveToWindow));
    AHSwz(UIWindow.class, @selector(makeKeyAndVisible), @selector(ah_makeKeyAndVisible));

    dispatch_async(dispatch_get_main_queue(), ^{ AHStartTimer(); });
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { AHStartTimer(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { AHStartTimer(); }];
}
