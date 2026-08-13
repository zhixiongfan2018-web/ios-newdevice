#import <Foundation/Foundation.h>
#import <Security/Security.h>
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

static OSStatus NDKCAddOrUpdate(NSMutableDictionary *add, NSDictionary *del, NSData *data) {
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st == errSecMissingEntitlement && add[(__bridge id)kSecAttrAccessGroup]) {
        [add removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    if (st == errSecDuplicateItem) {
        NSMutableDictionary *q = [del mutableCopy] ?: [@{ (__bridge id)kSecClass: add[(__bridge id)kSecClass] } mutableCopy];
        st = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
    }
    return st;
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
        if ([raw[@"agrp"] isKindOfClass:[NSString class]] && [raw[@"agrp"] length]) del[(__bridge id)kSecAttrAccessGroup] = raw[@"agrp"];
        if (!del[(__bridge id)kSecAttrAccount] && !del[(__bridge id)kSecAttrService] && !del[(__bridge id)kSecAttrServer]) continue;

        SecItemDelete((__bridge CFDictionaryRef)del);

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
        NSLog(@"[NewDevice] in-app keychain restore %@ ok=%lu/%lu from %@", bid, (unsigned long)ok, (unsigned long)total, path);
        if (ok > 0) {
            if (pendingPath.length) [fm removeItemAtPath:pending error:nil];
            break; // success — stop; on failure try next candidate path
        }
    }
}

%ctor {
    @autoreleasepool {
        if (!NDShouldLoadTweak()) return;
        // MUST be synchronous: Venmo reads Keychain (tokens + Encryption_symmetricKey)
        // during early launch. A delayed restore races and leaves the UI logged-out.
        @try {
            NDApplyPendingKeychainRestore();
        } @catch (__unused NSException *ex) {
        }
        // Second pass after UIKit is up (covers Home not ready in very early ctor)
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                NDApplyPendingKeychainRestore();
            } @catch (__unused NSException *ex) {
            }
        });
    }
}
