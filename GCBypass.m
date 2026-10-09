// MRzefvGC - Game Center / PlayFab login fallback for re-signed apps.
// 1) Fakes a signed-in GKLocalPlayer so games stop blocking on "Game Center Login Required".
// 2) Rewrites PlayFab LoginWithGameCenter -> LoginWithCustomID (guest account tied to this install).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>
#import <objc/runtime.h>
#import <Security/Security.h>

#define MG_VER @"AirShare v5"

static NSString *CID(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *c = [d stringForKey:@"mrzefv.gc.cid"];
    if (!c.length) {
        c = NSUUID.UUID.UUIDString;
        [d setObject:c forKey:@"mrzefv.gc.cid"];
        [d synchronize];
    }
    return c;
}

static NSString *FakeNum(void) {
    const char *s = CID().UTF8String;
    unsigned long long h = 1469598103934665603ULL;
    while (*s) { h ^= (unsigned char)*s++; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%010llu", h % 10000000000ULL];
}

static IMP hookIMP(Class c, SEL s, id blk) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    IMP n = imp_implementationWithBlock(blk);
    if (!class_addMethod(c, s, n, method_getTypeEncoding(m))) method_setImplementation(m, n);
    return orig;
}


static void dbg(NSString *t) {
    NSLog(@"[MRzefvGC] %@", t);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:UIWindowScene.class]) {
                for (UIWindow *x in ((UIWindowScene *)sc).windows) { if (x.isKeyWindow) { w = x; break; } }
                if (!w) w = ((UIWindowScene *)sc).windows.firstObject;
            }
            if (w) break;
        }
        if (!w) return;
        [[w viewWithTag:7731] removeFromSuperview];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(8, w.bounds.size.height - 150, w.bounds.size.width - 16, 140)];
        l.tag = 7731; l.numberOfLines = 8; l.font = [UIFont boldSystemFontOfSize:11]; l.textColor = UIColor.whiteColor;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75]; l.text = [MG_VER stringByAppendingFormat:@" | %@", t]; l.userInteractionEnabled = NO;
        [w addSubview:l];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
    });
}

#pragma mark - GameKit

static void hookGameKit(void) {
    Class c = GKLocalPlayer.class;
    hookIMP(c, @selector(setAuthenticateHandler:), (id)^(id self, void (^h)(UIViewController *, NSError *)) {
        if (!h) return;
        void (^hh)(UIViewController *, NSError *) = [h copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            hh(nil, nil);
            [NSNotificationCenter.defaultCenter postNotificationName:GKPlayerAuthenticationDidChangeNotificationName object:nil];
        });
    });
    hookIMP(c, @selector(isAuthenticated), (id)^BOOL(id self) { return YES; });
    hookIMP(c, @selector(isUnderage), (id)^BOOL(id self) { return NO; });
    hookIMP(c, @selector(isMultiplayerGamingRestricted), (id)^BOOL(id self) { return NO; });
    hookIMP(c, @selector(playerID), (id)^NSString *(id self) { return [@"G:" stringByAppendingString:FakeNum()]; });
    hookIMP(c, @selector(gamePlayerID), (id)^NSString *(id self) { return [@"A:_" stringByAppendingString:FakeNum()]; });
    hookIMP(c, @selector(teamPlayerID), (id)^NSString *(id self) { return [@"T:_" stringByAppendingString:FakeNum()]; });
    hookIMP(c, @selector(alias), (id)^NSString *(id self) { return @"Player"; });
    hookIMP(c, @selector(displayName), (id)^NSString *(id self) { return @"Player"; });
    hookIMP(c, @selector(fetchItemsForIdentityVerificationSignature:), (id)^(id self, void (^cb)(NSURL *, NSData *, NSData *, uint64_t, NSError *)) {
        if (!cb) return;
        NSMutableData *sig = [NSMutableData dataWithLength:256];
        NSMutableData *salt = [NSMutableData dataWithLength:4];
        SecRandomCopyBytes(NULL, 4, salt.mutableBytes);
        uint64_t ts = (uint64_t)([NSDate date].timeIntervalSince1970 * 1000);
        NSURL *u = [NSURL URLWithString:@"https://static.gc.apple.com/public-key/gc-prod-4.cer"];
        dispatch_async(dispatch_get_main_queue(), ^{ cb(u, sig, salt, ts, nil); });
    });
}


#pragma mark - Title ID scan

static NSString *scanTitle(void) {
    static NSString *found; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *root = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Data"];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray *subs = [fm subpathsAtPath:root];
        for (NSString *rel in subs) {
            NSString *last = rel.lastPathComponent.lowercaseString;
            if (!([last hasSuffix:@".assets"] || [last hasPrefix:@"globalgamemanagers"] || [last hasPrefix:@"level"] || [last isEqualToString:@"data.unity3d"])) continue;
            NSData *d = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:rel] options:NSDataReadingMappedIfSafe error:nil];
            if (d.length < 64) continue;
            const uint8_t *b = d.bytes; size_t n = d.length;
            const char *needle = "playfabapi.com"; size_t nl = strlen(needle);
            const uint8_t *cur = b;
            while (cur < b + n) {
                const uint8_t *hit = memmem(cur, (size_t)(b + n - cur), needle, nl);
                if (!hit) break;
                long pos = hit - b;
                long lo = pos - 200 < 0 ? 0 : pos - 200;
                long hi = pos + 200 > (long)n - 8 ? (long)n - 8 : pos + 200;
                for (long i = lo; i < hi; i++) {
                    uint32_t len; memcpy(&len, b + i, 4);
                    if (len < 4 || len > 6) continue;
                    BOOL ok = YES;
                    for (uint32_t k = 0; k < len; k++) {
                        uint8_t ch = b[i + 4 + k];
                        if (!((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'F'))) { ok = NO; break; }
                    }
                    if (!ok) continue;
                    if (b[i + 4 + len] != 0) continue;
                    found = [[NSString alloc] initWithBytes:b + i + 4 length:len encoding:NSASCIIStringEncoding];
                    return;
                }
                cur = hit + nl;
            }
        }
    });
    return found;
}

#pragma mark - PlayFab

static NSData *readStream(NSInputStream *s) {
    NSMutableData *d = [NSMutableData data];
    uint8_t buf[4096];
    [s open];
    NSInteger n;
    while ((n = [s read:buf maxLength:sizeof(buf)]) > 0) [d appendBytes:buf length:(NSUInteger)n];
    [s close];
    return d;
}

static BOOL isGC(NSURLRequest *r) {
    NSURL *u = r.URL;
    NSString *h = u.host.lowercaseString;
    if (!h || ![h hasSuffix:@"playfabapi.com"]) return NO;
    return [u.path rangeOfString:@"LoginWithGameCenter" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSURLRequest *rewrite(NSURLRequest *r, NSData *given, NSData **outBody) {
    if (!r || !isGC(r)) return nil;
    NSData *b = given ?: r.HTTPBody;
    if (!b && r.HTTPBodyStream) b = readStream(r.HTTPBodyStream);
    id j = b.length ? [NSJSONSerialization JSONObjectWithData:b options:0 error:nil] : nil;
    NSDictionary *o = [j isKindOfClass:NSDictionary.class] ? j : @{};
    NSMutableDictionary *n = [NSMutableDictionary dictionary];
    NSString *tid = [o[@"TitleId"] isKindOfClass:NSString.class] ? o[@"TitleId"] : nil;
    NSString *host = r.URL.host.lowercaseString;
    if (!tid.length && [host hasSuffix:@".playfabapi.com"]) tid = [host componentsSeparatedByString:@"."].firstObject;
    if (!tid.length) tid = [NSBundle.mainBundle objectForInfoDictionaryKey:@"PlayFabTitleId"];
    if (!tid.length) tid = [NSUserDefaults.standardUserDefaults stringForKey:@"mrzefv.gc.title"];
    NSString *src = tid.length ? @"req" : @"";
    if (!tid.length) { tid = scanTitle(); if (tid.length) src = @"scan"; }
    if (tid.length) [NSUserDefaults.standardUserDefaults setObject:tid forKey:@"mrzefv.gc.title"];
    if (tid.length) n[@"TitleId"] = tid;
    if (o[@"InfoRequestParameters"]) n[@"InfoRequestParameters"] = o[@"InfoRequestParameters"];
    n[@"CustomId"] = CID();
    n[@"CreateAccount"] = @YES;
    NSData *nb = [NSJSONSerialization dataWithJSONObject:n options:0 error:nil];
    NSString *old = r.URL.absoluteString;
    NSString *s = [old stringByReplacingOccurrencesOfString:@"LoginWithGameCenter" withString:@"LoginWithCustomID"
                                                    options:NSCaseInsensitiveSearch range:NSMakeRange(0, old.length)];
    NSMutableURLRequest *m = [r mutableCopy];
    m.URL = [NSURL URLWithString:s];
    m.HTTPBody = nb;
    m.HTTPBodyStream = nil;
    [m setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [m setValue:[NSString stringWithFormat:@"%lu", (unsigned long)nb.length] forHTTPHeaderField:@"Content-Length"];
    if (outBody) *outBody = nb;
    NSMutableURLRequest *pr = [m mutableCopy];
    pr.HTTPMethod = @"POST"; pr.HTTPBody = nb; pr.timeoutInterval = 15;
    [pr setValue:@"UnitySDK-2.217.250704" forHTTPHeaderField:@"X-PlayFabSDK"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:pr completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSString *body = d.length ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
        if (body.length > 260) body = [body substringToIndex:260];
        dbg([NSString stringWithFormat:@"MRzefvGC probe -> HTTP %ld err=%@ body=%@", (long)((NSHTTPURLResponse *)resp).statusCode, e.localizedDescription ?: (d.length ? @"-" : @"timeout/none"), body]);
    }] resume];
    dbg([NSString stringWithFormat:@"MRzefvGC: GameCenter login -> CustomID  host=%@ title=%@(%@) bodyIn=%lu", host, tid ?: @"NONE", src, (unsigned long)b.length]);
    return m;
}

typedef id (*F1)(id, SEL, NSURLRequest *);
typedef id (*F2)(id, SEL, NSURLRequest *, id);
typedef id (*F3)(id, SEL, NSURLRequest *, NSData *);
typedef id (*F4)(id, SEL, NSURLRequest *, NSData *, id);

static IMP o_data, o_data_c, o_up_d, o_up_d_c, o_stream;

static void hookNetwork(void) {
    NSURLSession *s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    Class c = object_getClass(s);
    o_data = hookIMP(c, @selector(dataTaskWithRequest:), (id)^id(id self, NSURLRequest *r) {
        NSData *nb = nil; NSURLRequest *n = rewrite(r, nil, &nb);
        return ((F1)o_data)(self, @selector(dataTaskWithRequest:), n ?: r);
    });
    o_data_c = hookIMP(c, @selector(dataTaskWithRequest:completionHandler:), (id)^id(id self, NSURLRequest *r, id h) {
        NSData *nb = nil; NSURLRequest *n = rewrite(r, nil, &nb);
        return ((F2)o_data_c)(self, @selector(dataTaskWithRequest:completionHandler:), n ?: r, h);
    });
    o_up_d = hookIMP(c, @selector(uploadTaskWithRequest:fromData:), (id)^id(id self, NSURLRequest *r, NSData *d) {
        NSData *nb = nil; NSURLRequest *n = rewrite(r, d, &nb);
        return ((F3)o_up_d)(self, @selector(uploadTaskWithRequest:fromData:), n ?: r, n ? nb : d);
    });
    o_up_d_c = hookIMP(c, @selector(uploadTaskWithRequest:fromData:completionHandler:), (id)^id(id self, NSURLRequest *r, NSData *d, id h) {
        NSData *nb = nil; NSURLRequest *n = rewrite(r, d, &nb);
        return ((F4)o_up_d_c)(self, @selector(uploadTaskWithRequest:fromData:completionHandler:), n ?: r, n ? nb : d, h);
    });
    o_stream = hookIMP(c, @selector(uploadTaskWithStreamedRequest:), (id)^id(id self, NSURLRequest *r) {
        if (isGC(r)) {
            NSData *nb = nil; NSURLRequest *n = rewrite(r, nil, &nb);
            if (n) return [(NSURLSession *)self uploadTaskWithRequest:n fromData:nb];
        }
        return ((F1)o_stream)(self, @selector(uploadTaskWithStreamedRequest:), r);
    });
}

__attribute__((constructor)) static void mrzefv_gc_init(void) {
    @autoreleasepool {
        hookGameKit();
        hookNetwork();
        NSLog(@"[MRzefvGC] loaded");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ dbg(@"dylib loaded, waiting for login"); });
        [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:@"https://3703.playfabapi.com/"] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            dbg([NSString stringWithFormat:@"net test 3703.playfabapi.com -> HTTP %ld err=%@", (long)((NSHTTPURLResponse *)r).statusCode, e.localizedDescription ?: @"-"]);
        }] resume];
    }
}
