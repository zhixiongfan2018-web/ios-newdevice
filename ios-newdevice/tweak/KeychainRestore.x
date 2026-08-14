#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import "NDTweakState.h"
#import "NDPaths.h"
#import "NDSafeLoad.h"

/// AMG puts per-app Keychain dumps at Documents/akc.plist.
/// SecItemAdd from NewDevice/daemon often cannot target Venmo's access group;
/// restoring inside the host app process uses the app's own keychain entitlements.

static NSData *NDKCDataValue(id v) {
    if ([v isKindOfClass:[NSData class]]) return (NSData *)v;
    if ([v isKindOfClass:[NSString class]]) {
        NSData *b64 = [[NSData alloc] initWithBase64EncodedString:(NSString *)v options:0];
        if (b64.length) return b64;
        return [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding];
    }
    return nil;
}

static id NDAccessibleForPdmn(NSString *pdmn) {
    // Avoid deprecated kSecAttrAccessibleAlways* (iOS 12+); map Always → AfterFirstUnlock.
    if ([pdmn isEqualToString:@"ak"]) return (__bridge id)kSecAttrAccessibleWhenUnlocked;
    if ([pdmn isEqualToString:@"ck"] || [pdmn isEqualToString:@"dk"]) {
        return (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    }
    if ([pdmn isEqualToString:@"aku"]) return (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    if ([pdmn isEqualToString:@"cku"] || [pdmn isEqualToString:@"dku"]) {
        return (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    }
    return (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
}

/// Prefer the host process's real keychain-access-groups (App Store vs sideload team IDs differ).
static NSArray<NSString *> *NDHostKeychainAccessGroups(void) {
    static NSArray<NSString *> *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *out = [NSMutableArray array];
        @try {
            // SecTaskCopyValueForEntitlement — soft-link via dlsym (not always in public headers)
            void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
            if (!sec) sec = dlopen("/var/jb/usr/lib/libsecurity.dylib", RTLD_NOW);
            typedef void *(*SecTaskCreateFromSelf_t)(CFAllocatorRef);
            typedef CFTypeRef (*SecTaskCopyValueForEntitlement_t)(void *, CFStringRef, CFErrorRef *);
            SecTaskCreateFromSelf_t create = sec ? (SecTaskCreateFromSelf_t)dlsym(sec, "SecTaskCreateFromSelf") : NULL;
            SecTaskCopyValueForEntitlement_t copyEnt = sec ? (SecTaskCopyValueForEntitlement_t)dlsym(sec, "SecTaskCopyValueForEntitlement") : NULL;
            if (create && copyEnt) {
                void *task = create(NULL);
                if (task) {
                    CFTypeRef groups = copyEnt(task, CFSTR("keychain-access-groups"), NULL);
                    if (groups && CFGetTypeID(groups) == CFArrayGetTypeID()) {
                        for (id g in (__bridge NSArray *)groups) {
                            if ([g isKindOfClass:[NSString class]] && [g length]) [out addObject:g];
                        }
                    }
                    if (groups) CFRelease(groups);
                    CFTypeRef appId = copyEnt(task, CFSTR("application-identifier"), NULL);
                    if (appId && CFGetTypeID(appId) == CFStringGetTypeID()) {
                        NSString *aid = (__bridge NSString *)appId;
                        if (aid.length && ![out containsObject:aid]) [out addObject:aid];
                    }
                    if (appId) CFRelease(appId);
                    CFRelease(task);
                }
            }
        } @catch (__unused NSException *ex) {
        }
        // Known Venmo team IDs as last-resort candidates (App Store + common sideload)
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        if ([bid isEqualToString:@"net.kortina.labs.Venmo"]) {
            for (NSString *g in @[
                     @"6DEPQ9SPDK.net.kortina.labs.Venmo",
                     @"55377VK7X2.net.kortina.labs.Venmo",
                 ]) {
                if (![out containsObject:g]) [out addObject:g];
            }
        }
        cached = [out copy];
    });
    return cached;
}

static NSString *NDHostKeychainAccessGroup(void) {
    return NDHostKeychainAccessGroups().firstObject;
}
__attribute__((unused)) static void NDTouchHostAgrp(void) { (void)NDHostKeychainAccessGroup(); }

static OSStatus NDKCTryAdd(NSMutableDictionary *add, NSDictionary *del, NSData *data, NSString *agrpOrNil) {
    if (agrpOrNil.length) add[(__bridge id)kSecAttrAccessGroup] = agrpOrNil;
    else [add removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st == errSecDuplicateItem) {
        NSMutableDictionary *q = [del mutableCopy] ?: [@{ (__bridge id)kSecClass: add[(__bridge id)kSecClass] } mutableCopy];
        if (agrpOrNil.length) q[(__bridge id)kSecAttrAccessGroup] = agrpOrNil;
        else [q removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        st = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
    }
    return st;
}

static OSStatus NDKCAddOrUpdate(NSMutableDictionary *add, NSDictionary *del, NSData *data) {
    // Prefer dump agrp (if any), then each host entitlement group, then no agrp.
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    id dumpAgrp = del[(__bridge id)kSecAttrAccessGroup];
    if ([dumpAgrp isKindOfClass:[NSString class]] && [dumpAgrp length]) [candidates addObject:dumpAgrp];
    for (NSString *g in NDHostKeychainAccessGroups()) {
        if (g.length && ![candidates containsObject:g]) [candidates addObject:g];
    }
    [candidates addObject:@""]; // sentinel = no agrp

    OSStatus last = errSecParam;
    for (NSString *g in candidates) {
        NSString *use = g.length ? g : nil;
        OSStatus st = NDKCTryAdd(add, del, data, use);
        if (st == errSecSuccess) return st;
        last = st;
        if (st != errSecMissingEntitlement && st != errSecAuthFailed) {
            // keep trying other groups on entitlement mismatch; otherwise stop early on weird errors
            if (st != -34018 /* errSecMissingEntitlement legacy */) {
                // still try next group — Venmo sideload often rejects App Store team id
            }
        }
    }
    return last;
}

static NSUInteger NDRestoreAkcDictionary(NSDictionary *akc, NSMutableArray *failNotes) {
    if (![akc isKindOfClass:[NSDictionary class]] || !akc.count) return 0;
    NSUInteger ok = 0;
    for (id key in akc) {
        NSDictionary *raw = akc[key];
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSData *vData = NDKCDataValue(raw[@"v_Data"]);
        if (!vData.length) continue;
        NSString *cls = [raw[@"class"] isKindOfClass:[NSString class]] ? raw[@"class"] : @"genp";
        if ([cls isEqualToString:@"cert"] || [cls isEqualToString:@"certificate"]) continue;

        CFStringRef secClass = [cls isEqualToString:@"inet"] ? kSecClassInternetPassword : kSecClassGenericPassword;
        NSMutableDictionary *del = [@{ (__bridge id)kSecClass: (__bridge id)secClass } mutableCopy];
        if ([raw[@"acct"] isKindOfClass:[NSString class]] && [raw[@"acct"] length]) del[(__bridge id)kSecAttrAccount] = raw[@"acct"];
        if ([raw[@"svce"] isKindOfClass:[NSString class]] && [raw[@"svce"] length]) del[(__bridge id)kSecAttrService] = raw[@"svce"];
        if ([raw[@"srvr"] isKindOfClass:[NSString class]] && [raw[@"srvr"] length]) del[(__bridge id)kSecAttrServer] = raw[@"srvr"];
        if ([raw[@"agrp"] isKindOfClass:[NSString class]] && [raw[@"agrp"] length]) {
            del[(__bridge id)kSecAttrAccessGroup] = raw[@"agrp"];
        }
        if (!del[(__bridge id)kSecAttrAccount] && !del[(__bridge id)kSecAttrService] && !del[(__bridge id)kSecAttrServer]) continue;

        // Delete under dump agrp + every host group + no agrp (clear stale writes)
        NSMutableArray<NSString *> *delGroups = [NSMutableArray array];
        if ([raw[@"agrp"] isKindOfClass:[NSString class]] && [raw[@"agrp"] length]) {
            [delGroups addObject:raw[@"agrp"]];
        }
        for (NSString *g in NDHostKeychainAccessGroups()) {
            if (g.length && ![delGroups containsObject:g]) [delGroups addObject:g];
        }
        for (NSString *g in delGroups) {
            NSMutableDictionary *d = [del mutableCopy];
            d[(__bridge id)kSecAttrAccessGroup] = g;
            SecItemDelete((__bridge CFDictionaryRef)d);
        }
        NSMutableDictionary *delBare = [del mutableCopy];
        [delBare removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        SecItemDelete((__bridge CFDictionaryRef)delBare);

        NSMutableDictionary *add = [del mutableCopy];
        add[(__bridge id)kSecValueData] = vData;
        if ([raw[@"pdmn"] isKindOfClass:[NSString class]]) {
            add[(__bridge id)kSecAttrAccessible] = NDAccessibleForPdmn(raw[@"pdmn"]);
        } else {
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        }
        if ([raw[@"sync"] isKindOfClass:[NSNumber class]]) {
            add[(__bridge id)kSecAttrSynchronizable] = raw[@"sync"];
        }

        OSStatus st = NDKCAddOrUpdate(add, del, vData);
        if (st == errSecSuccess) {
            ok++;
        } else if (failNotes.count < 8) {
            [failNotes addObject:[NSString stringWithFormat:@"%@ st=%d", key, (int)st]];
        }
    }
    return ok;
}

static NSUInteger NDRestoreKeychainArray(NSArray *items, NSMutableArray *failNotes) {
    if (![items isKindOfClass:[NSArray class]] || !items.count) return 0;
    NSUInteger ok = 0;
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *cls = item[@"class"] ?: @"generic";
        if ([cls isEqualToString:@"certificate"]) continue;
        NSData *data = NDKCDataValue(item[@"data"]);
        if (!data.length) continue;
        CFStringRef secClass = [cls isEqualToString:@"internet"] ? kSecClassInternetPassword : kSecClassGenericPassword;
        NSMutableDictionary *del = [@{ (__bridge id)kSecClass: (__bridge id)secClass } mutableCopy];
        if ([item[@"account"] isKindOfClass:[NSString class]] && [item[@"account"] length]) del[(__bridge id)kSecAttrAccount] = item[@"account"];
        if ([item[@"service"] isKindOfClass:[NSString class]] && [item[@"service"] length]) del[(__bridge id)kSecAttrService] = item[@"service"];
        if ([item[@"server"] isKindOfClass:[NSString class]] && [item[@"server"] length]) del[(__bridge id)kSecAttrServer] = item[@"server"];
        if ([item[@"accessGroup"] isKindOfClass:[NSString class]] && [item[@"accessGroup"] length]) del[(__bridge id)kSecAttrAccessGroup] = item[@"accessGroup"];
        if (!del[(__bridge id)kSecAttrAccount] && !del[(__bridge id)kSecAttrService] && !del[(__bridge id)kSecAttrServer]) continue;
        SecItemDelete((__bridge CFDictionaryRef)del);
        NSMutableDictionary *add = [del mutableCopy];
        add[(__bridge id)kSecValueData] = data;
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        OSStatus st = NDKCAddOrUpdate(add, del, data);
        if (st == errSecSuccess) ok++;
        else if (failNotes.count < 8) {
            [failNotes addObject:[NSString stringWithFormat:@"%@/%@ st=%d", item[@"service"] ?: @"", item[@"account"] ?: @"", (int)st]];
        }
    }
    return ok;
}

static BOOL NDLooksLikeAkcDict(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]] || !d.count) return NO;
    id first = d.allValues.firstObject;
    if (![first isKindOfClass:[NSDictionary class]]) return NO;
    return first[@"v_Data"] != nil || first[@"svce"] != nil || first[@"acct"] != nil;
}

static NSUInteger NDClearOwnKeychain(void) {
    // Running inside Venmo: SecItemDelete with only class deletes everything this
    // process is entitled to see (survives uninstall — App/daemon cannot reach it).
    NSUInteger waves = 0;
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity,
    ];
    for (id secClass in classes) {
        NSDictionary *del = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
        };
        OSStatus st = SecItemDelete((__bridge CFDictionaryRef)del);
        if (st == errSecSuccess) waves++;
        // Known Venmo access groups (App Store + sideload)
        for (NSString *agrp in @[
                 @"55377VK7X2.net.kortina.labs.Venmo",
                 @"6DEPQ9SPDK.net.kortina.labs.Venmo",
             ]) {
            NSDictionary *delG = @{
                (__bridge id)kSecClass: secClass,
                (__bridge id)kSecAttrAccessGroup: agrp,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
            };
            if (SecItemDelete((__bridge CFDictionaryRef)delG) == errSecSuccess) waves++;
        }
    }
    return waves;
}

static void NDApplyPendingKeychainClear(void) {
    if (!NDVenmoPendingClearKeychain()) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger waves = NDClearOwnKeychain();
    NSString *report = [NSString stringWithFormat:
                        @"bid=net.kortina.labs.Venmo\nmode=in-app-clear\nwaves=%lu\ntime=%@\n",
                        (unsigned long)waves, [NSDate date]];
    for (NSString *dir in @[
             @"/var/jb/Library/NewDevice",
             @"/var/mobile/Media/NewDevice",
         ]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [report writeToFile:[dir stringByAppendingPathComponent:@"last-venmo-kc-clear.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSString *homeDocs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [fm createDirectoryAtPath:homeDocs withIntermediateDirectories:YES attributes:nil error:nil];
    [report writeToFile:[homeDocs stringByAppendingPathComponent:@"nd-kc-cleared.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // Remove pending flags so next launch is idle
    for (NSString *p in @[
             @"/var/jb/Library/NewDevice/pending-clear-kc/net.kortina.labs.Venmo",
             @"/var/mobile/Media/NewDevice/pending-clear-kc/net.kortina.labs.Venmo",
             @"/var/jb/Library/NewDevice/pending-akc/net.kortina.labs.Venmo.txt",
             @"/var/mobile/Media/NewDevice/pending-akc/net.kortina.labs.Venmo.txt",
         ]) {
        [fm removeItemAtPath:p error:nil];
    }
    for (NSString *name in @[@"akc.plist", @"nd-akc-ok.txt"]) {
        [fm removeItemAtPath:[homeDocs stringByAppendingPathComponent:name] error:nil];
    }
    NSLog(@"[NewDevice] in-app Venmo keychain clear waves=%lu", (unsigned long)waves);
}

static void NDApplyPendingKeychainRestore(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (!bid.length) return;
    // Skip non-app hosts
    if ([bid hasPrefix:@"com.apple."] && ![bid containsString:@"mobilesafari"]) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *homeDocs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [paths addObject:[homeDocs stringByAppendingPathComponent:@"akc.plist"]];
    [paths addObject:[homeDocs stringByAppendingPathComponent:@"keychain-full.plist"]];

    NDTweakState *st = [NDTweakState shared];
    NSString *rec = st.profile.name;
    if (rec.length && ![rec isEqualToString:@"原始机器"]) {
        NSString *dir = [NDPaths appsBackupDirForRecord:rec bundleId:bid];
        [paths addObject:[dir stringByAppendingPathComponent:@"akc.plist"]];
        [paths addObject:[dir stringByAppendingPathComponent:@"Documents/akc.plist"]];
        [paths addObject:[dir stringByAppendingPathComponent:@"keychain-full.plist"]];
    }

    // Explicit pending pointer written by restoreHolo
    NSString *pending = [[[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-akc"] stringByAppendingPathComponent:[bid stringByAppendingString:@".txt"]];
    NSString *pendingPath = [NSString stringWithContentsOfFile:pending encoding:NSUTF8StringEncoding error:nil];
    pendingPath = [pendingPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (pendingPath.length) [paths insertObject:pendingPath atIndex:0];

    NSString *marker = [homeDocs stringByAppendingPathComponent:@"nd-akc-ok.txt"];
    for (NSString *path in paths) {
        if (![fm fileExistsAtPath:path]) continue;
        NSMutableArray *fails = [NSMutableArray array];
        NSUInteger ok = 0;
        NSUInteger total = 0;
        if ([path.lastPathComponent.lowercaseString containsString:@"keychain"]) {
            NSArray *items = [NSArray arrayWithContentsOfFile:path];
            total = [items isKindOfClass:[NSArray class]] ? items.count : 0;
            ok = NDRestoreKeychainArray(items, fails);
        } else {
            NSDictionary *akc = [NSDictionary dictionaryWithContentsOfFile:path];
            if (!NDLooksLikeAkcDict(akc)) continue;
            total = akc.count;
            ok = NDRestoreAkcDictionary(akc, fails);
        }
        if (total == 0) continue;

        NSString *report = [NSString stringWithFormat:
                            @"bid=%@\nsource=%@\ntotal=%lu\nok=%lu\ntime=%@\nfails=%@\n",
                            bid, path, (unsigned long)total, (unsigned long)ok,
                            [NSDate date], fails.count ? [fails componentsJoinedByString:@"; "] : @"-"];
        [fm createDirectoryAtPath:homeDocs withIntermediateDirectories:YES attributes:nil error:nil];
        [report writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // Also mirror under NewDevice runtime for Filza when sandbox is awkward
        NSString *rt = [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"last-akc-restore.txt"];
        [fm createDirectoryAtPath:[rt stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [report writeToFile:rt atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *media = @"/var/mobile/Media/NewDevice/last-akc-restore.txt";
        [fm createDirectoryAtPath:[media stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [report writeToFile:media atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[NewDevice] in-app keychain restore %@ ok=%lu/%lu from %@", bid, (unsigned long)ok, (unsigned long)total, path);
        if (ok > 0) {
            if (pendingPath.length) [fm removeItemAtPath:pending error:nil];
            break; // success — stop; on failure try next candidate path
        }
    }
}

%ctor {
    @autoreleasepool {
        static BOOL sRan = NO;
        void (^run)(void) = ^{
            @try {
                if (sRan) return;
                NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
                if (NDBundleIsJailbreakTool(bid)) return;
                NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
                if (!bid.length) {
                    if (![proc isEqualToString:@"Venmo"]) return;
                }
                if ([bid hasPrefix:@"com.apple."] && ![bid containsString:@"mobilesafari"]) return;
                if (!bid.length && ![proc isEqualToString:@"Venmo"]) return;
                if (!bid.length) bid = @"net.kortina.labs.Venmo";

                // Idle Venmo launches: do nothing (avoid crash surface).
                BOOL wantClear = NDIsVenmoHost() && NDVenmoPendingClearKeychain();
                BOOL wantRestore = NDVenmoPendingAkcRestore();
                if (NDIsVenmoHost() && !wantClear && !wantRestore) return;

                NSString *homeDocs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm createDirectoryAtPath:homeDocs withIntermediateDirectories:YES attributes:nil error:nil];

                sRan = YES;
                NSString *loaded = [NSString stringWithFormat:@"bid=%@\nproc=%@\ntime=%@\nclear=%@\nrestore=%@\n",
                                    bid, proc, [NSDate date],
                                    wantClear ? @"1" : @"0", wantRestore ? @"1" : @"0"];
                [loaded writeToFile:[homeDocs stringByAppendingPathComponent:@"nd-tweak-loaded.txt"]
                         atomically:YES encoding:NSUTF8StringEncoding error:nil];
                NSString *rt = @"/var/jb/Library/NewDevice/last-tweak-loaded.txt";
                [fm createDirectoryAtPath:[rt stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                [loaded writeToFile:rt atomically:YES encoding:NSUTF8StringEncoding error:nil];

                if (wantClear) {
                    NDApplyPendingKeychainClear();
                    return; // never restore in the same pass
                }

                // If a prior successful restore exists, don't re-hit SecItem (races / SIGBUS).
                NSString *marker = [homeDocs stringByAppendingPathComponent:@"nd-akc-ok.txt"];
                NSString *prev = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
                BOOL alreadyOK = (prev.length && [prev rangeOfString:@"ok="].location != NSNotFound &&
                                  ![prev containsString:@"ok=0"]);
                if (alreadyOK) {
                    NSRange r = [prev rangeOfString:@"ok="];
                    if (r.location != NSNotFound) {
                        NSInteger n = [[prev substringFromIndex:r.location + 3] integerValue];
                        if (n > 0) return;
                    }
                }

                NDApplyPendingKeychainRestore();
            } @catch (__unused NSException *ex) {
            }
        };

        // Never run SecItemAdd in %ctor synchronously — wait for main runloop.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (NDIsVenmoHost()) {
                // One delayed pass only (avoid multi-retry races with mParticle)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), run);
            } else {
                run();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), run);
            }
        });
    }
}
