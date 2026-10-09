// AirHide.dylib
// 1) Kills the full-screen onboarding splash ("Welcome / Cracked by Blatant /
//    Instant Certificates / More Apps / CLOSING IN x.xs") the moment it tries
//    to show. Everything else keeps running.
// 2) Replaces it with the DELvEK onboarding: bottom card (~1/4 screen) with the
//    host app's icon / name / bundle id, AirCore info, 5s countdown + haptics.
//
// Detection (UIKit AND SwiftUI splashes):
//   - WHO drew it: any window / presented VC / full-screen subview created from
//     code in an injected image (bare .dylib inside the .app, or any image path
//     matching AHBlockNames) is blocked.
//   - WHAT it is: class / module names matching AHBlockNames.
//   - TEXT: UILabel markers (UIKit splashes).
//   - 0.1s sweep for 25s after launch / foreground as a safety net.
//
// Config below. Kill switch: NSUserDefaults bool "AirHideOff" = YES.
// Onboarding: shows on every cold launch and every return from background.
// Set AH_ONBOARD_EVERY_LAUNCH to 0 for once-per-install.
// NSUserDefaults bool "AirHideOnboardOff" = YES hides it.
// Haptics / vibration / sounds triggered by the blocked splash are muted too.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <string.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreHaptics/CoreHaptics.h>

// Optional: put AirShareLogo.png in the repo root; build.sh embeds it here.
#if __has_include("AirShareLogo.h")
#include "AirShareLogo.h"
#define AH_HAS_LOGO 1
#endif

#pragma mark - Config

#define AH_ONBOARD_EVERY_LAUNCH 1
#define AH_COUNTDOWN_SECONDS 5

static NSArray<NSString *> *AHBlockNames(void) {
    return @[ @"blatant" ];
}
static NSArray<NSString *> *AHKeepNames(void) {
    return @[ ]; // lowercase image names of YOUR dylibs allowed to show full-screen UI
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
static NSString *const kOnbOff = @"AirHideOnboardOff";
static NSString *const kOnbSeen = @"AirHideOnboardSeen";
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
    static NSMutableDictionary<NSValue *, NSNumber *> *ccache;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ ccache = [NSMutableDictionary dictionary]; });
    NSValue *k = [NSValue valueWithNonretainedObject:c];
    @synchronized (ccache) {
        NSNumber *n = ccache[k];
        if (n) return n.boolValue;
        BOOL r = AHPathBlocked(class_getImageName(c)) || AHNameBlocked(NSStringFromClass(c));
        ccache[k] = @(r);
        return r;
    }
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
    if (v.hidden || v.alpha < 0.01) return nil;
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
    }
    // no removeFromSuperview: the owner keeps running (and finishes) its own
    // countdown / cleanup, so nothing is left looping in the background
}

static BOOL AHAncestorHidden(UIView *v) {
    while (v) {
        if (v.hidden || v.alpha < 0.01) return YES;
        v = v.superview;
    }
    return NO;
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
    if (AHAncestorHidden(label)) return NO;
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
    if (v.hidden || v.alpha < 0.01) return;
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

#pragma mark - Onboarding: data

static UIColor *AHOrange(void) { return [UIColor colorWithRed:196/255.0 green:138/255.0 blue:75/255.0 alpha:1]; }
static UIColor *AHGreen(void)  { return [UIColor colorWithRed:92/255.0 green:200/255.0 blue:122/255.0 alpha:1]; }
static UIColor *AHGray(void)   { return [UIColor colorWithWhite:1 alpha:0.62]; }

static UIImage *AHAirShareLogo(void) {
#ifdef AH_HAS_LOGO
    NSData *d = [NSData dataWithBytes:AirShareLogo_png length:AirShareLogo_png_len];
    UIImage *img = [UIImage imageWithData:d scale:UIScreen.mainScreen.scale];
    if (img) return img;
#endif
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [[UIColor colorWithRed:196/255.0 green:138/255.0 blue:75/255.0 alpha:1] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 64, 64) cornerRadius:16] fill];
        NSDictionary *a = @{ NSFontAttributeName: [UIFont systemFontOfSize:38 weight:UIFontWeightBold],
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:0.1 alpha:1] };
        CGSize z = [@"A" sizeWithAttributes:a];
        [@"A" drawAtPoint:CGPointMake((64 - z.width) / 2, (64 - z.height) / 2) withAttributes:a];
    }];
}

static NSString *AHAppName(void) {
    NSDictionary *i = NSBundle.mainBundle.infoDictionary;
    return i[@"CFBundleDisplayName"] ?: i[@"CFBundleName"] ?: @"App";
}

static UIImage *AHAppIcon(void) {
    NSDictionary *icons = NSBundle.mainBundle.infoDictionary[@"CFBundleIcons"];
    NSDictionary *primary = [icons isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
    NSArray *files = [primary isKindOfClass:NSDictionary.class] ? primary[@"CFBundleIconFiles"] : nil;
    if ([files isKindOfClass:NSArray.class]) {
        for (NSString *n in files.reverseObjectEnumerator) {
            UIImage *im = [UIImage imageNamed:n];
            if (im) return im;
        }
    }
    NSString *name = [primary isKindOfClass:NSDictionary.class] ? primary[@"CFBundleIconName"] : nil;
    if (name) {
        UIImage *im = [UIImage imageNamed:name];
        if (im) return im;
    }
    return [UIImage systemImageNamed:@"app.fill"];
}

// Time left on the signing certificate / provisioning profile ("35d 20h 3m").
static NSString *AHPPQTimer(void) {
    NSString *p = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData *d = p ? [NSData dataWithContentsOfFile:p] : nil;
    if (!d) return @"--";
    NSData *a = [@"<?xml" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *b = [@"</plist>" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange r1 = [d rangeOfData:a options:0 range:NSMakeRange(0, d.length)];
    NSRange r2 = [d rangeOfData:b options:0 range:NSMakeRange(0, d.length)];
    if (r1.location == NSNotFound || r2.location == NSNotFound || r2.location < r1.location) return @"--";
    NSData *pl = [d subdataWithRange:NSMakeRange(r1.location, r2.location + r2.length - r1.location)];
    NSDictionary *pd = [NSPropertyListSerialization propertyListWithData:pl options:0 format:NULL error:NULL];
    NSDate *exp = [pd isKindOfClass:NSDictionary.class] ? pd[@"ExpirationDate"] : nil;
    if (![exp isKindOfClass:NSDate.class]) return @"--";
    NSInteger s = (NSInteger)[exp timeIntervalSinceNow];
    if (s <= 0) return @"expired";
    return [NSString stringWithFormat:@"%ldd %ldh %ldm", (long)(s / 86400), (long)((s % 86400) / 3600), (long)((s % 3600) / 60)];
}

#pragma mark - Onboarding: UI

static UILabel *AHLabel(NSString *t, UIFont *f, UIColor *c, NSInteger lines) {
    UILabel *l = [UILabel new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = t;
    l.font = f;
    l.textColor = c;
    l.numberOfLines = lines;
    return l;
}

static void AHPin(UIView *v, UIView *to) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:to.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:to.bottomAnchor],
        [v.leadingAnchor constraintEqualToAnchor:to.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:to.trailingAnchor],
    ]];
}

static UIImage *AHSig(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
    for (NSString *n in @[ @"signature.zh", @"signature", @"pencil.and.scribble" ]) {
        UIImage *i = [UIImage systemImageNamed:n withConfiguration:cfg];
        if (i) return i;
    }
    return nil;
}

static UIView *AHFeature(NSString *sym, NSString *title, UIColor *titleColor, NSString *sub) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightRegular];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sym withConfiguration:cfg]];
    iv.tintColor = [UIColor colorWithRed:232/255.0 green:154/255.0 blue:74/255.0 alpha:1];
    iv.contentMode = UIViewContentModeTop;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [iv.widthAnchor constraintEqualToConstant:34].active = YES;

    UILabel *t = AHLabel(title, [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold], titleColor, 0);
    UILabel *s = AHLabel(sub, [UIFont systemFontOfSize:13], [UIColor colorWithWhite:1 alpha:0.6], 0);
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[t, s]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 2;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iv, col]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 12;
    return row;
}

@interface AHOnbVC : UIViewController
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) NSInteger left;
@property (nonatomic, copy) void (^onDone)(void);
@end

@implementation AHOnbVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _dim = [[UIView alloc] initWithFrame:self.view.bounds];
    _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    _dim.alpha = 0;
    [self.view addSubview:_dim];

    _card = [UIView new];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = 30;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.masksToBounds = YES;
    _card.layer.borderWidth = 0.5;
    _card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    [self.view addSubview:_card];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    [_card addSubview:blur];
    AHPin(blur, _card);
    UIView *tint = [UIView new];
    tint.backgroundColor = [UIColor colorWithRed:22/255.0 green:22/255.0 blue:25/255.0 alpha:0.82];
    tint.userInteractionEnabled = NO;
    [_card addSubview:tint];
    AHPin(tint, _card);

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_card.bottomAnchor constraintEqualToAnchor:sg.bottomAnchor constant:-6],
        [_card.topAnchor constraintGreaterThanOrEqualToAnchor:sg.topAnchor constant:12],
    ]];

    // ---- header: icon | name + bundle + tagline | signature + badges ----
    UIImageView *icon = [[UIImageView alloc] initWithImage:AHAppIcon()];
    icon.contentMode = UIViewContentModeScaleAspectFill;
    icon.layer.cornerRadius = 14;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.layer.masksToBounds = YES;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:60].active = YES;
    [icon.heightAnchor constraintEqualToConstant:60].active = YES;

    UILabel *name = AHLabel([NSString stringWithFormat:@"[ %@ ]", AHAppName()],
                            [UIFont systemFontOfSize:21 weight:UIFontWeightSemibold], UIColor.whiteColor, 1);
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.6;
    UILabel *bid = AHLabel(NSBundle.mainBundle.bundleIdentifier ?: @"--",
                           [UIFont systemFontOfSize:13], [UIColor colorWithWhite:1 alpha:0.55], 1);
    bid.adjustsFontSizeToFitWidth = YES;
    bid.minimumScaleFactor = 0.6;
    UILabel *tag = AHLabel(@"AirCore is now active, helping you keep your certificate safer.",
                           [UIFont systemFontOfSize:12.5], [UIColor colorWithWhite:1 alpha:0.55], 0);
    UIStackView *txt = [[UIStackView alloc] initWithArrangedSubviews:@[name, bid, tag]];
    txt.axis = UILayoutConstraintAxisVertical;
    txt.spacing = 3;
    [txt setCustomSpacing:6 afterView:bid];
    txt.layoutMarginsRelativeArrangement = YES;
    txt.layoutMargins = UIEdgeInsetsMake(8, 0, 0, 0);

    UIImageView *sigIv = [[UIImageView alloc] initWithImage:AHSig()];
    sigIv.tintColor = AHOrange();
    sigIv.contentMode = UIViewContentModeScaleAspectFit;
    NSMutableAttributedString *mk = [[NSMutableAttributedString alloc] initWithString:@"MrZEFv" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: AHOrange() }];
    [mk appendAttributedString:[[NSAttributedString alloc] initWithString:@"™" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:8],
        NSForegroundColorAttributeName: AHOrange(),
        NSBaselineOffsetAttributeName: @5 }]];
    UILabel *mkl = AHLabel(nil, [UIFont systemFontOfSize:13], AHOrange(), 1);
    mkl.attributedText = mk;
    UIStackView *sigRow = [[UIStackView alloc] initWithArrangedSubviews:@[sigIv, mkl]];
    sigRow.axis = UILayoutConstraintAxisHorizontal;
    sigRow.alignment = UIStackViewAlignmentCenter;
    sigRow.spacing = 6;

    [sigRow setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [sigRow setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIView *rt = sigRow;

    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[icon, txt, rt]];
    head.axis = UILayoutConstraintAxisHorizontal;
    head.alignment = UIStackViewAlignmentTop;
    head.spacing = 10;
    head.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:head];

    // ---- footer: Continue (N) ----
    _btn = [UIButton buttonWithType:UIButtonTypeCustom];
    _btn.translatesAutoresizingMaskIntoConstraints = NO;
    _btn.backgroundColor = AHOrange();
    _btn.layer.cornerRadius = 23;
    _btn.layer.cornerCurve = kCACornerCurveContinuous;
    _btn.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    UIColor *dark = [UIColor colorWithWhite:0.1 alpha:1];
    [_btn setTitleColor:dark forState:UIControlStateNormal];
    [_btn setTitleColor:dark forState:UIControlStateDisabled];
    [_btn addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
    _left = AH_COUNTDOWN_SECONDS;
    [_btn setTitle:[NSString stringWithFormat:@"Continue (%ld)", (long)_left] forState:UIControlStateNormal];
    _btn.enabled = NO;
    [_card addSubview:_btn];

    // ---- body: links row, info rows, even more ----
    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.showsVerticalScrollIndicator = YES;
    _scroll.alwaysBounceVertical = NO;
    [_card addSubview:_scroll];

    UIStackView *body = [UIStackView new];
    body.axis = UILayoutConstraintAxisVertical;
    body.spacing = 12;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:body];

    UIFont *lf = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    UIImageView *sic = [[UIImageView alloc] initWithImage:AHAirShareLogo()];
    sic.contentMode = UIViewContentModeScaleAspectFill;
    sic.layer.cornerRadius = 6;
    sic.layer.masksToBounds = YES;
    sic.translatesAutoresizingMaskIntoConstraints = NO;
    [sic.widthAnchor constraintEqualToConstant:24].active = YES;
    [sic.heightAnchor constraintEqualToConstant:24].active = YES;
    UILabel *l1 = AHLabel(@"AirShare.lol", lf, AHGreen(), 1);
    UIStackView *l1s = [[UIStackView alloc] initWithArrangedSubviews:@[sic, l1]];
    l1s.axis = UILayoutConstraintAxisHorizontal;
    l1s.alignment = UIStackViewAlignmentCenter;
    l1s.spacing = 8;
    UILabel *l2 = AHLabel(@"\u0141  DONATE LTC", lf, [UIColor colorWithWhite:1 alpha:0.9], 1);
    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[l1s, l2]];
    row1.axis = UILayoutConstraintAxisHorizontal;
    row1.alignment = UIStackViewAlignmentCenter;
    row1.distribution = UIStackViewDistributionEqualSpacing;

    UILabel *l3 = AHLabel(nil, lf, AHGreen(), 1);
    NSMutableAttributedString *ppq = [[NSMutableAttributedString alloc] initWithString:@"PPQ TiMER" attributes:@{
        NSFontAttributeName: lf, NSForegroundColorAttributeName: AHGreen() }];
    [ppq appendAttributedString:[[NSAttributedString alloc] initWithString:[@" : " stringByAppendingString:AHPPQTimer()] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:14], NSForegroundColorAttributeName: AHGray() }]];
    l3.attributedText = ppq;

    UIStackView *links = [[UIStackView alloc] initWithArrangedSubviews:@[row1, l3]];
    links.axis = UILayoutConstraintAxisVertical;
    links.alignment = UIStackViewAlignmentFill;
    links.spacing = 10;
    [body addArrangedSubview:links];
    [body setCustomSpacing:16 afterView:links];

    [body addArrangedSubview:AHFeature(@"checkmark.shield", @"AIRCORE PROTECTiON", UIColor.whiteColor,
        @"Blocks risky Apple endpoints to help you keep your certificate alive while you use this app.")];
    [body addArrangedSubview:AHFeature(@"hand.tap", @"ANTiPiRACY SiGNATURE", UIColor.whiteColor,
        @"App was Downloaded from AirShare.lol")];
    [body addArrangedSubview:AHFeature(@"info.circle", @"AirShare REPOSiTORY", AHGreen(),
        @"Trusted status. This app was scanned & verified!")];

    UILabel *more = AHLabel(@"& even more…", [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], UIColor.whiteColor, 1);
    UILabel *revoke = AHLabel(@"App can only be revoked if apple invalidates AppiD.",
                              [UIFont systemFontOfSize:13], [UIColor colorWithWhite:1 alpha:0.55], 0);
    UIStackView *moreCol = [[UIStackView alloc] initWithArrangedSubviews:@[more, revoke]];
    moreCol.axis = UILayoutConstraintAxisVertical;
    moreCol.spacing = 3;
    [body addArrangedSubview:moreCol];

    [NSLayoutConstraint activateConstraints:@[
        [head.topAnchor constraintEqualToAnchor:_card.topAnchor constant:18],
        [head.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [head.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],

        [_btn.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [_btn.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],
        [_btn.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-14],
        [_btn.heightAnchor constraintEqualToConstant:46],

        [_scroll.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:16],
        [_scroll.bottomAnchor constraintEqualToAnchor:_btn.topAnchor constant:-16],
        [_scroll.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [_scroll.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],

        [body.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
        [body.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
        [body.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor],
        [body.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor],
    ]];
    // card grows to fit every row; only scrolls if the screen is too short
    NSLayoutConstraint *fit = [_scroll.heightAnchor constraintEqualToAnchor:body.heightAnchor];
    fit.priority = 999;
    fit.active = YES;

    _card.transform = CGAffineTransformMakeTranslation(0, 500);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.6
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.card.transform = CGAffineTransformIdentity;
        self.dim.alpha = 1;
    } completion:^(BOOL f) { [self.scroll flashScrollIndicators]; }];

    __weak typeof(self) ws = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        AHOnbVC *s = ws;
        if (!s) { [t invalidate]; return; }
        s.left--;
        if (s.left > 0) {
            [s.btn setTitle:[NSString stringWithFormat:@"Continue (%ld)", (long)s.left] forState:UIControlStateNormal];
        } else {
            [t invalidate];
            s.timer = nil;
            [s.btn setTitle:@"Continue" forState:UIControlStateNormal];
            s.btn.enabled = YES;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)finish {
    [_timer invalidate];
    _timer = nil;
    [UIView animateWithDuration:0.3 animations:^{
        self.card.transform = CGAffineTransformMakeTranslation(0, self.card.bounds.size.height + 120);
        self.dim.alpha = 0;
    } completion:^(BOOL f) {
        if (self.onDone) self.onDone();
    }];
}

@end

static UIWindow *gOnbWin;

static void AHShowOnboarding(void) {
    if (gOnbWin || AHOff()) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:kOnbOff]) return;
#if !AH_ONBOARD_EVERY_LAUNCH
    if ([d boolForKey:kOnbSeen]) return;
#endif
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelAlert + 50;
    w.backgroundColor = UIColor.clearColor;
    AHOnbVC *vc = [AHOnbVC new];
    vc.onDone = ^{
        gOnbWin.hidden = YES;
        gOnbWin = nil;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kOnbSeen];
    };
    w.rootViewController = vc;
    gOnbWin = w;
    w.hidden = NO;
}

static BOOL gNeedOnb = YES;

static void AHScheduleOnboarding(void) {
    if (!gNeedOnb) return;
    gNeedOnb = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AHShowOnboarding(); });
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
    if (!gMain && !blocked && self != gOnbWin) gMain = self;
    if (blocked && self != AHMainWindow()) {
        self.hidden = YES;
        return;
    }
    [self ah_makeKeyAndVisible];
}
- (void)ah_setHidden:(BOOL)h {
    if (!h && !AHOff() && self != gOnbWin && self != AHMainWindow() && gMain &&
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

#pragma mark - Haptics / sounds from the blocked splash

static BOOL AHMute(void) {
    return !AHOff() && AHStackFromBlocked();
}

@interface UIImpactFeedbackGenerator (AirHide)
@end
@implementation UIImpactFeedbackGenerator (AirHide)
- (void)ah_impactOccurred { if (AHMute()) return; [self ah_impactOccurred]; }
- (void)ah_impactOccurredWithIntensity:(CGFloat)i { if (AHMute()) return; [self ah_impactOccurredWithIntensity:i]; }
@end

@interface UINotificationFeedbackGenerator (AirHide)
@end
@implementation UINotificationFeedbackGenerator (AirHide)
- (void)ah_notificationOccurred:(UINotificationFeedbackType)t { if (AHMute()) return; [self ah_notificationOccurred:t]; }
@end

@interface UISelectionFeedbackGenerator (AirHide)
@end
@implementation UISelectionFeedbackGenerator (AirHide)
- (void)ah_selectionChanged { if (AHMute()) return; [self ah_selectionChanged]; }
@end

@interface CHHapticEngine (AirHide)
@end
@implementation CHHapticEngine (AirHide)
- (BOOL)ah_startAndReturnError:(NSError **)e {
    if (AHMute()) {
        if (e) *e = [NSError errorWithDomain:@"AirHide" code:1 userInfo:nil];
        return NO;
    }
    return [self ah_startAndReturnError:e];
}
- (BOOL)ah_playPatternFromURL:(NSURL *)u error:(NSError **)e {
    if (AHMute()) return YES;
    return [self ah_playPatternFromURL:u error:e];
}
- (BOOL)ah_playPatternFromData:(NSData *)d error:(NSError **)e {
    if (AHMute()) return YES;
    return [self ah_playPatternFromData:d error:e];
}
@end

// AudioToolbox vibrate / alert sounds (dyld interpose)
static void ah_AudioServicesPlaySystemSound(SystemSoundID s) {
    if (AHMute()) return;
    AudioServicesPlaySystemSound(s);
}
static void ah_AudioServicesPlayAlertSound(SystemSoundID s) {
    if (AHMute()) return;
    AudioServicesPlayAlertSound(s);
}
static void ah_AudioServicesPlaySystemSoundWithCompletion(SystemSoundID s, void (^c)(void)) {
    if (AHMute()) { if (c) dispatch_async(dispatch_get_main_queue(), c); return; }
    AudioServicesPlaySystemSoundWithCompletion(s, c);
}
static void ah_AudioServicesPlayAlertSoundWithCompletion(SystemSoundID s, void (^c)(void)) {
    if (AHMute()) { if (c) dispatch_async(dispatch_get_main_queue(), c); return; }
    AudioServicesPlayAlertSoundWithCompletion(s, c);
}

#define AH_INTERPOSE(R, O) \
    __attribute__((used)) static struct { const void *r; const void *o; } _ahi_##O \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&R, (const void *)(unsigned long)&O };
AH_INTERPOSE(ah_AudioServicesPlaySystemSound, AudioServicesPlaySystemSound)
AH_INTERPOSE(ah_AudioServicesPlayAlertSound, AudioServicesPlayAlertSound)
AH_INTERPOSE(ah_AudioServicesPlaySystemSoundWithCompletion, AudioServicesPlaySystemSoundWithCompletion)
AH_INTERPOSE(ah_AudioServicesPlayAlertSoundWithCompletion, AudioServicesPlayAlertSoundWithCompletion)

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
    AHSwz(UIImpactFeedbackGenerator.class, @selector(impactOccurred), @selector(ah_impactOccurred));
    AHSwz(UIImpactFeedbackGenerator.class, @selector(impactOccurredWithIntensity:), @selector(ah_impactOccurredWithIntensity:));
    AHSwz(UINotificationFeedbackGenerator.class, @selector(notificationOccurred:), @selector(ah_notificationOccurred:));
    AHSwz(UISelectionFeedbackGenerator.class, @selector(selectionChanged), @selector(ah_selectionChanged));
    AHSwz(CHHapticEngine.class, @selector(startAndReturnError:), @selector(ah_startAndReturnError:));
    AHSwz(CHHapticEngine.class, @selector(playPatternFromURL:error:), @selector(ah_playPatternFromURL:error:));
    AHSwz(CHHapticEngine.class, @selector(playPatternFromData:error:), @selector(ah_playPatternFromData:error:));

    dispatch_async(dispatch_get_main_queue(), ^{ AHStartTimer(); });
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { AHStartTimer(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        AHStartTimer();
        AHScheduleOnboarding();
    }];
#if AH_ONBOARD_EVERY_LAUNCH
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { gNeedOnb = YES; }];
#endif
}
