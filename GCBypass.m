// MRzefvGC - Game Center / PlayFab login fallback for re-signed apps.
// 1) Fakes a signed-in GKLocalPlayer so games stop blocking on "Game Center Login Required".
// 2) Rewrites PlayFab LoginWithGameCenter -> LoginWithCustomID (guest account tied to this install).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>
#import <objc/runtime.h>
#import <Security/Security.h>

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
    if (o[@"TitleId"]) n[@"TitleId"] = o[@"TitleId"];
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
    }
}
