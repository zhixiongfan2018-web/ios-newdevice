#ifndef NDSafeLoad_h
#define NDSafeLoad_h

#import <Foundation/Foundation.h>

/// Return YES if NewDevice tweak must NOT load in this process.
/// Keeps Sileo / Dopamine / package managers stable so jailbreak tooling is not disrupted.
static inline BOOL NDBundleIsJailbreakTool(NSString *bundleId) {
    // Empty bundle id is common for daemons (e.g. CommCenter) — not a jailbreak tool by itself.
    if (!bundleId.length) return NO;
    static NSSet<NSString *> *deny;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        deny = [NSSet setWithArray:@[
            @"xyz.willy.Sileo",
            @"org.coolstar.SileoStore",
            @"org.coolstar.SileoNightly",
            @"com.saurik.Cydia",
            @"xyz.willy.Zebra",
            @"com.getzbra.zebra",
            @"com.opa334.Dopamine",
            @"com.opa334.TrollStore",
            @"com.opa334.TrollHelper",
            @"org.coolstar.SafeMode",
        ]];
    });
    if ([deny containsObject:bundleId]) return YES;
    if ([bundleId hasPrefix:@"xyz.willy.Sileo"]) return YES;
    if ([bundleId hasPrefix:@"com.opa334.Dopamine"]) return YES;
    NSString *lower = bundleId.lowercaseString;
    if ([lower containsString:@"sileo"]) return YES;
    if ([lower containsString:@"cydia"]) return YES;
    if ([lower containsString:@"zebra"]) return YES;
    return NO;
}

static inline BOOL NDShouldLoadTweak(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (NDBundleIsJailbreakTool(bid)) return NO;
    // Empty bundle id is common in very early %ctor — do NOT refuse here;
    // callers should retry on main queue once UIKit/app bundle is ready.
    if (!bid.length) return YES;
    return YES;
}

#endif /* NDSafeLoad_h */
