#import "NDAppDataManager.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <Security/Security.h>

extern char **environ;

@interface NDAppDataManager ()
@property (nonatomic, copy, readwrite) NSString *lastRestoreReport;
- (NSArray *)NDKeychainItemsFromAMGAkcDictionary:(NSDictionary *)akc;
- (NSArray *)NDLoadKeychainItemsFromBackupDir:(NSString *)dir;
- (BOOL)NDBackupDirHasKeychainDump:(NSString *)dir;
- (void)NDMaterializeKeychainFullFromAMGInAppDir:(NSString *)dstRoot importKeychain:(BOOL)importKC;
- (void)NDImportAMGHolographicFromDirectory:(NSString *)amgRecordDir intoRecord:(NSString *)recordName depth:(NSInteger)depth;
@end

@implementation NDAppDataManager

+ (instancetype)shared {
    static NDAppDataManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        m = [NDAppDataManager new];
        // MCM APIs needed for correct data-container paths on iOS 12+
        dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
    });
    return m;
}

+ (void)loadMCM {
    dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
}

/// App Store apps store Keychain under TEAMID.bundleId when akc.plist has no agrp.
/// Writing without agrp from newdeviced lands in the daemon's own group — Venmo never sees it.
- (NSString *)defaultKeychainAccessGroupForBundleId:(NSString *)bid {
    if (!bid.length) return nil;
    static NSMutableDictionary *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        if (cache[bid]) return cache[bid];
    }
    NSString *team = nil;
    @try {
        Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
        if (LSApplicationProxy && [LSApplicationProxy respondsToSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")]) {
            id (*msg)(Class, SEL, id) = (void *)objc_msgSend;
            id proxy = msg(LSApplicationProxy, NSSelectorFromString(@"applicationProxyForIdentifier:"), bid);
            if (proxy) {
                if ([proxy respondsToSelector:NSSelectorFromString(@"teamID")]) {
                    team = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"teamID"));
                }
                if (![team isKindOfClass:[NSString class]] || !team.length) {
                    if ([proxy respondsToSelector:NSSelectorFromString(@"applicationIdentifier")]) {
                        // some proxies expose full application-identifier TEAMID.bid
                        NSString *appId = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"applicationIdentifier"));
                        if ([appId isKindOfClass:[NSString class]] && [appId containsString:@"."] && ![appId isEqualToString:bid]) {
                            // If already TEAMID.bid use as agrp directly
                            if ([appId hasSuffix:bid] || [appId containsString:bid]) {
                                @synchronized (cache) { cache[bid] = appId; }
                                return appId;
                            }
                        }
                    }
                }
            }
        }
    } @catch (__unused NSException *ex) {}
    if (![team isKindOfClass:[NSString class]] || !team.length) {
        // Fallback: scan bundle for embedded.mobileprovision TeamIdentifier (best-effort)
        @try {
            Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
            id (*msg)(Class, SEL, id) = (void *)objc_msgSend;
            id proxy = msg(LSApplicationProxy, NSSelectorFromString(@"applicationProxyForIdentifier:"), bid);
            NSURL *bundleURL = nil;
            if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) {
                bundleURL = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleURL"));
            }
            if ([bundleURL isKindOfClass:[NSURL class]]) {
                NSString *prov = [bundleURL.path stringByAppendingPathComponent:@"embedded.mobileprovision"];
                NSData *data = [NSData dataWithContentsOfFile:prov];
                if (data.length) {
                    NSString *raw = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
                    if (!raw) raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                    NSRange r = [raw rangeOfString:@"<key>TeamIdentifier</key>"];
                    if (r.location != NSNotFound) {
                        NSString *tail = [raw substringFromIndex:r.location];
                        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<string>([A-Z0-9]+)</string>"
                                                                                           options:0 error:nil];
                        NSTextCheckingResult *m = [re firstMatchInString:tail options:0 range:NSMakeRange(0, MIN((NSUInteger)200, tail.length))];
                        if (m.numberOfRanges >= 2) team = [tail substringWithRange:[m rangeAtIndex:1]];
                    }
                }
            }
        } @catch (__unused NSException *ex) {}
    }
    if (![team isKindOfClass:[NSString class]] || !team.length) return nil;
    NSString *agrp = [NSString stringWithFormat:@"%@.%@", team, bid];
    @synchronized (cache) { cache[bid] = agrp; }
    NSLog(@"[NewDevice] keychain agrp for %@ => %@", bid, agrp);
    return agrp;
}

- (void)runCommand:(NSString *)launchPath arguments:(NSArray<NSString *> *)args {
    pid_t pid = 0;
    const char *path = launchPath.fileSystemRepresentation;
    NSUInteger count = args.count;
    char **argv = calloc(count + 2, sizeof(char *));
    argv[0] = (char *)path;
    for (NSUInteger i = 0; i < count; i++) {
        argv[i + 1] = (char *)args[i].UTF8String;
    }
    argv[count + 1] = NULL;
    posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (pid > 0) {
        int status = 0;
        waitpid(pid, &status, 0);
    }
    free(argv);
}

- (void)terminateApps:(NSArray<NSString *> *)bundleIds {
    for (NSString *bid in bundleIds) {
        if (!bid.length) continue;
        NSMutableSet<NSString *> *names = [NSMutableSet set];
        // Prefer CFBundleExecutable from LSApplicationProxy
        Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
        if (LSApplicationProxy && [LSApplicationProxy respondsToSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id proxy = [LSApplicationProxy performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:bid];
#pragma clang diagnostic pop
            if (proxy) {
                if ([proxy respondsToSelector:NSSelectorFromString(@"bundleExecutable")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    NSString *exec = [proxy performSelector:NSSelectorFromString(@"bundleExecutable")];
#pragma clang diagnostic pop
                    if ([exec isKindOfClass:[NSString class]] && exec.length) [names addObject:exec];
                }
                if ([proxy respondsToSelector:NSSelectorFromString(@"localizedName")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    NSString *lname = [proxy performSelector:NSSelectorFromString(@"localizedName")];
#pragma clang diagnostic pop
                    if ([lname isKindOfClass:[NSString class]] && lname.length) [names addObject:lname];
                }
            }
        }
        // Fallbacks: last bundle component (often wrong) + full bid
        if (bid.pathExtension.length) {
            // ignore
        }
        NSString *last = bid.lastPathComponent;
        if (last.length) [names addObject:last];
        for (NSString *proc in names) {
            [self runCommand:@"/var/jb/usr/bin/killall" arguments:@[@"-9", proc]];
            [self runCommand:@"/usr/bin/killall" arguments:@[@"-9", proc]];
            [self runCommand:@"/var/jb/usr/bin/killall" arguments:@[@"-9", [proc stringByReplacingOccurrencesOfString:@" " withString:@""]]];
        }
    }
}

- (NSString *)NDScanContainerUnderRoots:(NSArray<NSString *> *)roots identifier:(NSString *)identifier {
    if (!identifier.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *appsRoot in roots) {
        NSArray *uuids = [fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
        for (NSString *uuid in uuids) {
            if (uuid.length < 30) continue; // UUID dirs
            NSString *dir = [appsRoot stringByAppendingPathComponent:uuid];
            NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
            id mid = plist[@"MCMMetadataIdentifier"] ?: plist[@"identifier"] ?: plist[@"MCMMetadataInfo"][@"MCMMetadataIdentifier"];
            if ([mid isKindOfClass:[NSString class]] && [mid isEqualToString:identifier]) return dir;
            // Heuristic: Preferences/<bundleId>.plist is almost always present after first launch
            NSString *pref = [[dir stringByAppendingPathComponent:@"Library/Preferences"]
                              stringByAppendingPathComponent:[identifier stringByAppendingString:@".plist"]];
            if ([fm fileExistsAtPath:pref]) return dir;
        }
    }
    return nil;
}

- (NSURL *)NDMCMContainerURLSafe:(NSString *)identifier classNames:(NSArray<NSString *> *)classNames {
    // iOS 18+: ANY MCM containerWithIdentifier:… (even createIfNecessary:NO on
    // MCMDataContainer) still hits -[MCMContainer init…] and abort() — confirmed
    // live on SE/18.5 (newdeviced-2026-08-14-154645). Never call MCM here.
    if (!identifier.length) return nil;
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (v.majorVersion >= 18) {
        NSLog(@"[NewDevice] skip MCM lookup on iOS %ld for %@", (long)v.majorVersion, identifier);
        return nil;
    }
    [[self class] loadMCM];
    for (NSString *clsName in classNames) {
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        @try {
            SEL sel4 = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
            if ([cls respondsToSelector:sel4]) {
                BOOL existed = NO;
                NSError *err = nil;
                id (*msg4)(Class, SEL, id, BOOL, BOOL *, NSError *__autoreleasing *) = (void *)objc_msgSend;
                id container = msg4(cls, sel4, identifier, NO, &existed, &err);
                if (!container) continue;
                if ([container respondsToSelector:NSSelectorFromString(@"url")]) {
                    NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(container, NSSelectorFromString(@"url"));
                    if ([url isKindOfClass:[NSURL class]] && url.path.length) return url;
                }
                continue;
            }
            // Older signature — still never create
            SEL sel = NSSelectorFromString(@"containerWithIdentifier:error:");
            if (![cls respondsToSelector:sel]) continue;
            NSError *err2 = nil;
            id (*msg)(Class, SEL, id, NSError *__autoreleasing *) = (void *)objc_msgSend;
            id container = msg(cls, sel, identifier, &err2);
            if (!container) continue;
            if ([container respondsToSelector:NSSelectorFromString(@"url")]) {
                NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(container, NSSelectorFromString(@"url"));
                if ([url isKindOfClass:[NSURL class]] && url.path.length) return url;
            }
        } @catch (__unused NSException *ex) {
            NSLog(@"[NewDevice] MCM lookup exception for %@ class %@", identifier, clsName);
        }
    }
    return nil;
}

- (NSString *)containerPathForBundleId:(NSString *)bundleId {
    if (!bundleId.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) Metadata / Preferences scan — safe, no private API ABI risk
    NSString *scanned = [self NDScanContainerUnderRoots:@[
        @"/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/Application",
    ] identifier:bundleId];
    if (scanned.length) return scanned;

    // 2) LSApplicationProxy (no MCM abort)
    @try {
        Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
        if (LSApplicationProxy && [LSApplicationProxy respondsToSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")]) {
            id (*msg)(Class, SEL, id) = (void *)objc_msgSend;
            id proxy = msg(LSApplicationProxy, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleId);
            if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")]) {
                NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"dataContainerURL"));
                if ([url isKindOfClass:[NSURL class]] && url.path.length && [fm fileExistsAtPath:url.path]) return url.path;
            }
        }
    } @catch (__unused NSException *ex) {}

    // 3) MCM only on iOS < 18 (iOS 18 aborts inside MCMContainer init)
    NSURL *mcm = [self NDMCMContainerURLSafe:bundleId classNames:@[@"MCMAppDataContainer", @"MCMDataContainer"]];
    if (mcm.path.length && [fm fileExistsAtPath:mcm.path]) return mcm.path;

    return nil;
}

- (void)tryLaunchAppToCreateContainer:(NSString *)bundleId {
    // Only used by explicit restoreHolo — never during 一键新机
    if (!bundleId.length) return;
    @try {
        Class WS = NSClassFromString(@"LSApplicationWorkspace");
        if (!WS || ![WS respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) return;
        id (*msg0)(Class, SEL) = (void *)objc_msgSend;
        id ws = msg0(WS, NSSelectorFromString(@"defaultWorkspace"));
        if (!ws) return;
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if ([ws respondsToSelector:openSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(ws, openSel, bundleId);
            [NSThread sleepForTimeInterval:0.8];
            [self terminateApps:@[bundleId]];
            [NSThread sleepForTimeInterval:0.3];
        }
    } @catch (__unused NSException *ex) {}
}

/// Bring NewDevice to front so Venmo keychain work does not leave the user staring at the old session UI.
- (void)NDOpenBundleId:(NSString *)bundleId {
    if (!bundleId.length) return;
    @try {
        Class WS = NSClassFromString(@"LSApplicationWorkspace");
        if (!WS || ![WS respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) return;
        id (*msg0)(Class, SEL) = (void *)objc_msgSend;
        id ws = msg0(WS, NSSelectorFromString(@"defaultWorkspace"));
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (ws && [ws respondsToSelector:openSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(ws, openSel, bundleId);
        }
    } @catch (__unused NSException *ex) {}
}

- (BOOL)NDLaunchBundleSuspended:(NSString *)bundleId {
    if (!bundleId.length) return NO;
    @try {
        Class UIApp = NSClassFromString(@"UIApplication");
        if (!UIApp) return NO;
        id (*sharedMsg)(Class, SEL) = (void *)objc_msgSend;
        id app = sharedMsg(UIApp, NSSelectorFromString(@"sharedApplication"));
        SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
        if (app && [app respondsToSelector:sel]) {
            return ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bundleId, YES);
        }
    } @catch (__unused NSException *ex) {}
    return NO;
}

/// Start Venmo for in-app SecItem work without leaving the previous account on screen.
/// Prefer suspended launch; otherwise open briefly then bounce back to NewDevice.
- (NSString *)NDLaunchVenmoForKeychainWork {
    NSString *vbid = @"net.kortina.labs.Venmo";
    if ([self NDLaunchBundleSuspended:vbid]) {
        return @"launched=Venmo(suspended)";
    }
    [self NDOpenBundleId:vbid];
    // Let the process + tweak load, then reclaim foreground immediately.
    [NSThread sleepForTimeInterval:0.25];
    [self NDOpenBundleId:NDBundleID];
    return @"launched=Venmo(bounce-NewDevice)";
}

- (BOOL)mirrorTree:(NSString *)src to:(NSString *)dst error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return YES;
    unsigned long long srcBytes = [self byteSizeAtPath:src];
    // On iOS 18 Dopamine, spawned cp/rsync/ditto often LACK container-manager
    // entitlement even when WE have it — they return EPERM and may leave an
    // empty destination. Prefer in-process NSFileManager first (inherits our ents).
    NSError *copyErr = nil;
    if ([self copyItem:src to:dst error:&copyErr]) {
        unsigned long long dstBytes = [self byteSizeAtPath:dst];
        if (srcBytes == 0 || dstBytes >= srcBytes / 2) return YES;
        NSLog(@"[NewDevice] copyItem size mismatch %@ → %@ (%llu vs %llu)", src, dst, srcBytes, dstBytes);
    }
    // Fallback tools — only accept if payload actually landed
    for (NSArray *cmd in @[
        @[@"/var/jb/usr/bin/ditto", src, dst],
        @[@"/usr/bin/ditto", src, dst],
        @[@"/var/jb/usr/bin/rsync", @"-a", @"--delete", [src stringByAppendingString:@"/"], [dst stringByAppendingString:@"/"]],
        @[@"/usr/bin/rsync", @"-a", @"--delete", [src stringByAppendingString:@"/"], [dst stringByAppendingString:@"/"]],
    ]) {
        NSString *bin = cmd[0];
        if (![fm isExecutableFileAtPath:bin]) continue;
        if ([bin.lastPathComponent isEqualToString:@"ditto"]) {
            [fm removeItemAtPath:dst error:nil];
        } else {
            [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
        }
        [self runCommand:bin arguments:[cmd subarrayWithRange:NSMakeRange(1, cmd.count - 1)]];
        unsigned long long dstBytes = [self byteSizeAtPath:dst];
        if (dstBytes >= srcBytes / 2 || (srcBytes == 0 && [fm fileExistsAtPath:dst])) return YES;
    }
    if (error) *error = copyErr ?: [NSError errorWithDomain:@"NDAppDataManager" code:41 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法写入 %@（iOS18 需 container-manager 权限）", dst]
    }];
    return NO;
}

- (void)relaxProtectionAtPath:(NSString *)root {
    if (!root.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *top = @{
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
        NSFileOwnerAccountID: @501, // mobile
        NSFileGroupOwnerAccountID: @501,
    };
    [fm setAttributes:top ofItemAtPath:root error:nil];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    NSString *rel = nil;
    NSUInteger n = 0;
    while ((rel = [en nextObject])) {
        NSString *full = [root stringByAppendingPathComponent:rel];
        [fm setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:full error:nil];
        if (++n > 20000) break;
    }
}

- (BOOL)canAccessAppContainers:(NSString **)detailOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSError *err = nil;
    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:&err];
    if (uuids.count > 0) {
        if (detailOut) *detailOut = [NSString stringWithFormat:@"OK list %lu containers", (unsigned long)uuids.count];
        return YES;
    }
    // Probe readability of the directory itself
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:root isDirectory:&isDir];
    if (detailOut) {
        *detailOut = [NSString stringWithFormat:@"FAIL Containers access exists=%d dir=%d err=%@ — iOS18/Dopamine 需要 com.apple.private.security.container-manager",
                      exists, isDir, err.localizedDescription ?: @"empty listing"];
    }
    return NO;
}

- (void)writeRestoreReport:(NSString *)report {
    self.lastRestoreReport = report;
    [NDPaths ensureDirectories];
    NSString *path = [[NDPaths mediaHomeDir] stringByAppendingPathComponent:@"last-restore.txt"];
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NDPaths makePathWorldReadable:path];
}

- (BOOL)copyItem:(NSString *)src to:(NSString *)dst error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return YES;
    if ([fm fileExistsAtPath:dst]) {
        if (![fm removeItemAtPath:dst error:error]) return NO;
    }
    NSString *parent = [dst stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parent]) {
        if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    }
    NSError *copyErr = nil;
    if ([fm copyItemAtPath:src toPath:dst error:&copyErr]) return YES;
    // Fallback: cp -a (more reliable for large AMG trees / weird attrs on Dopamine)
    for (NSString *cp in @[@"/var/jb/usr/bin/cp", @"/usr/bin/cp", @"/bin/cp"]) {
        if (![fm isExecutableFileAtPath:cp]) continue;
        [self runCommand:cp arguments:@[@"-a", src, dst]];
        if ([fm fileExistsAtPath:dst]) return YES;
    }
    if (error) *error = copyErr;
    return NO;
}

- (unsigned long long)byteSizeAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;
    if (!isDir) return [[fm attributesOfItemAtPath:path error:nil] fileSize];
    unsigned long long total = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:path];
    while ([en nextObject]) {
        NSDictionary *attrs = [en fileAttributes];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) total += [attrs fileSize];
    }
    return total;
}

- (BOOL)clearDataForApps:(NSArray<NSString *> *)bundleIds error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *bid in bundleIds) {
        NSString *container = [self containerPathForBundleId:bid];
        if (container) {
            // Strong clear (AMG-style): wipe primary sandbox trees
            for (NSString *sub in @[@"Documents", @"Library", @"tmp", @"SystemData"]) {
                NSString *path = [container stringByAppendingPathComponent:sub];
                if ([fm fileExistsAtPath:path]) {
                    [fm removeItemAtPath:path error:nil];
                    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
                }
            }
            // Recreate common Library subdirs so apps don't crash on first launch
            for (NSString *sub in @[@"Library/Preferences", @"Library/Caches", @"Library/Cookies"]) {
                NSString *path = [container stringByAppendingPathComponent:sub];
                [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
            }
            // Wipe WebKit/WebsiteData trees (WKWebsiteDataStore on-disk)
            for (NSString *sub in @[@"Library/WebKit", @"Library/Caches/WebKit", @"Library/HTTPStorages"]) {
                NSString *path = [container stringByAppendingPathComponent:sub];
                if ([fm fileExistsAtPath:path]) [fm removeItemAtPath:path error:nil];
            }
        }

        // Also clear App Group containers when discoverable
        Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
        if (LSApplicationProxy && [LSApplicationProxy respondsToSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id proxy = [LSApplicationProxy performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:bid];
#pragma clang diagnostic pop
            if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"groupContainerURLs")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id groups = [proxy performSelector:NSSelectorFromString(@"groupContainerURLs")];
#pragma clang diagnostic pop
                if ([groups isKindOfClass:[NSDictionary class]]) {
                    for (NSURL *url in [(NSDictionary *)groups allValues]) {
                        if (![url isKindOfClass:[NSURL class]] || !url.path.length) continue;
                        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
                            NSString *path = [url.path stringByAppendingPathComponent:sub];
                            if ([fm fileExistsAtPath:path]) {
                                [fm removeItemAtPath:path error:nil];
                                [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
                            }
                        }
                    }
                }
            }
        }

        // Global prefs / caches outside sandbox (AMG strong clear)
        NSString *globalPref = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bid];
        if ([fm fileExistsAtPath:globalPref]) [fm removeItemAtPath:globalPref error:nil];
        NSString *cacheRoot = [NSString stringWithFormat:@"/var/mobile/Library/Caches/%@", bid];
        if ([fm fileExistsAtPath:cacheRoot]) [fm removeItemAtPath:cacheRoot error:nil];

        // Outside clear is best-effort only (iOS 18: Venmo partition invisible here).
        // Real Venmo session wipe is purgeVenmoSessionInApp / pending-clear-kc in-app.
        // Never clear keychain when the data container is missing — that nukes credentials
        // without a successful sandbox wipe/restore pair.
        if (container) {
            [self clearKeychainAccessGroupForBundleId:bid];
        } else if ([bid isEqualToString:@"net.kortina.labs.Venmo"]) {
            [self stageVenmoSessionClearOnly];
        }
        if ([bid isEqualToString:@"net.kortina.labs.Venmo"]) {
            NSFileManager *kfm = [NSFileManager defaultManager];
            for (NSString *p in @[
                     [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-akc/net.kortina.labs.Venmo.txt"],
                     @"/var/mobile/Media/NewDevice/pending-akc/net.kortina.labs.Venmo.txt",
                 ]) {
                [kfm removeItemAtPath:p error:nil];
            }
        }
    }
    return YES;
}

- (BOOL)backupApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName error:(NSError **)error {
    if (!recordName.length || [recordName isEqualToString:@"原始机器"]) return NO;
    for (NSString *bid in bundleIds) {
        NSString *container = [self containerPathForBundleId:bid];
        if (!container) continue;
        NSString *backupRoot = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
        unsigned long long existing = [self byteSizeAtPath:backupRoot];
        unsigned long long liveSize = 0;
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            liveSize += [self byteSizeAtPath:[container stringByAppendingPathComponent:sub]];
        }
        BOOL hasKC = [self NDBackupDirHasKeychainDump:backupRoot];
        // Never clobber a fat AMG stage OR any stage that still has akc with wiped/thin live.
        if ((existing > 32 * 1024 && liveSize < existing / 4) ||
            (hasKC && liveSize < existing)) {
            NSLog(@"[NewDevice] skip backup %@ — keep staged %lluKB (kc=%@), live only %lluKB",
                  bid, existing / 1024, hasKC ? @"yes" : @"no", liveSize / 1024);
            continue;
        }
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            NSString *src = [container stringByAppendingPathComponent:sub];
            NSString *dst = [backupRoot stringByAppendingPathComponent:sub];
            if (![self copyItem:src to:dst error:error]) {
                // continue best-effort
            }
        }
        [self backupKeychainHintsForApps:@[bid] toRecord:recordName];
        [self backupAppGroupsForBundleId:bid toRecord:recordName];
    }
    return YES;
}

/// Prefer Records staging; fall back to classic /var/mobile/AMG/<liveName>/<bid>
/// (import log names differ: ND uses 1916…-2026…, AMG live keeps +1916… 2026…).
- (NSString *)holographicSourceDirForBundleId:(NSString *)bid recordName:(NSString *)recordName sourceNote:(NSString **)noteOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *staged = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
    unsigned long long stagedBytes = [self byteSizeAtPath:staged];

    NSString *liveApp = nil;
    NSString *recDir = [NDPaths recordDir:recordName];
    NSString *livePathFile = [recDir stringByAppendingPathComponent:@"amg-live-path.txt"];
    NSString *liveNameFile = [recDir stringByAppendingPathComponent:@"amg-live-name.txt"];
    NSString *livePath = [[NSString stringWithContentsOfFile:livePathFile encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *liveName = [[NSString stringWithContentsOfFile:liveNameFile encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!livePath.length && liveName.length) {
        livePath = [@"/var/mobile/AMG" stringByAppendingPathComponent:liveName];
    }
    if (livePath.length) {
        NSString *cand = [livePath stringByAppendingPathComponent:bid];
        if ([fm fileExistsAtPath:cand]) liveApp = cand;
    }
    if (!liveApp.length) {
        // Exact match only on normalized names — substring matching picked wrong siblings.
        NSString *want = [[recordName stringByReplacingOccurrencesOfString:@"+" withString:@""]
                          stringByReplacingOccurrencesOfString:@" " withString:@"-"];
        while ([want containsString:@"--"]) want = [want stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
        NSArray *kids = [fm contentsOfDirectoryAtPath:@"/var/mobile/AMG" error:nil] ?: @[];
        for (NSString *k in kids) {
            NSString *got = [[k stringByReplacingOccurrencesOfString:@"+" withString:@""]
                             stringByReplacingOccurrencesOfString:@" " withString:@"-"];
            while ([got containsString:@"--"]) got = [got stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
            if (![got isEqualToString:want]) continue;
            NSString *cand = [[@"/var/mobile/AMG" stringByAppendingPathComponent:k] stringByAppendingPathComponent:bid];
            if ([fm fileExistsAtPath:cand]) { liveApp = cand; break; }
        }
    }

    unsigned long long liveBytes = liveApp.length ? [self byteSizeAtPath:liveApp] : 0;
    // Prefer the richer tree (classic live often fuller than a partial stage)
    if (liveBytes > stagedBytes && liveBytes > 0) {
        if (noteOut) *noteOut = [NSString stringWithFormat:@"AMG-live(%lluKB)", liveBytes / 1024];
        return liveApp;
    }
    if (stagedBytes > 0) {
        if (noteOut) *noteOut = [NSString stringWithFormat:@"Records/apps(%lluKB)", stagedBytes / 1024];
        return staged;
    }
    if (liveApp.length) {
        if (noteOut) *noteOut = [NSString stringWithFormat:@"AMG-live-fallback(%lluKB)", liveBytes / 1024];
        return liveApp;
    }
    if (noteOut) *noteOut = @"none";
    return nil;
}

- (BOOL)restoreOneApp:(NSString *)bid
           fromRecord:(NSString *)recordName
                lines:(NSMutableArray<NSString *> *)lines
              missing:(NSMutableArray<NSString *> *)missing {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *srcNote = nil;
    NSString *backupRoot = [self holographicSourceDirForBundleId:bid recordName:recordName sourceNote:&srcNote];
    if (!backupRoot.length) {
        [lines addObject:[NSString stringWithFormat:@"SKIP %@ (no Records/apps and no /var/mobile/AMG live)", bid]];
        return NO;
    }
    unsigned long long staged = [self byteSizeAtPath:backupRoot];
    if (staged == 0) {
        NSString *emptyNote = srcNote.length ? srcNote : @"-";
        [lines addObject:[NSString stringWithFormat:@"SKIP %@ (source empty %@)", bid, emptyNote]];
        return NO;
    }
    [lines addObject:[NSString stringWithFormat:@"SRC %@ <- %@", bid, (srcNote.length ? srcNote : backupRoot)]];

    NSString *container = nil;
    @try {
        container = [self containerPathForBundleId:bid];
    } @catch (__unused NSException *ex) {
        container = nil;
    }
    if (!container.length) {
        [missing addObject:bid];
        [lines addObject:[NSString stringWithFormat:@"FAIL %@ — 未找到数据容器（请确认已安装并打开过该 App）", bid]];
        return NO;
    }

    NSUInteger okSubs = 0;
    for (NSString *sub in @[@"Documents", @"Library", @"tmp", @"SystemData"]) {
        NSString *src = [backupRoot stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:src]) continue;
        NSString *dst = [container stringByAppendingPathComponent:sub];
        NSError *e = nil;
        if ([self mirrorTree:src to:dst error:&e]) {
            okSubs++;
            // iOS 18: imported files may keep Complete protection and be unreadable by Venmo until unlock races
            [self relaxProtectionAtPath:dst];
        } else {
            [lines addObject:[NSString stringWithFormat:@"  copy fail %@/%@: %@", bid, sub, e.localizedDescription ?: @"?"]];
        }
    }
    NSArray *kids = [fm contentsOfDirectoryAtPath:backupRoot error:nil] ?: @[];
    static NSSet *knownSubs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownSubs = [NSSet setWithArray:@[@"Documents", @"Library", @"tmp", @"SystemData"]];
    });
    for (NSString *kid in kids) {
        if ([kid hasPrefix:@"."]) continue;
        if ([knownSubs containsObject:kid]) continue;
        if ([kid.lowercaseString hasPrefix:@"keychain"]) continue;
        [self mirrorTree:[backupRoot stringByAppendingPathComponent:kid]
                      to:[container stringByAppendingPathComponent:kid]
                   error:nil];
    }
    BOOL hasKC = [self NDBackupDirHasKeychainDump:backupRoot];
    NSString *kcStats = [self restoreKeychainHintsForApps:@[bid] fromRecord:recordName];

    // Ensure live Documents has akc.plist for in-app tweak restore (access-group safe).
    // Always overwrite — stale/empty akc left from a prior failed pass blocks login.
    NSString *liveDocsPath = [container stringByAppendingPathComponent:@"Documents"];
    if (hasKC) {
        NSString *liveAkc = [liveDocsPath stringByAppendingPathComponent:@"akc.plist"];
        for (NSString *rel in @[@"Documents/akc.plist", @"akc.plist"]) {
            NSString *src = [backupRoot stringByAppendingPathComponent:rel];
            if (![fm fileExistsAtPath:src]) continue;
            [fm createDirectoryAtPath:liveDocsPath withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:liveAkc error:nil];
            if ([fm copyItemAtPath:src toPath:liveAkc error:nil]) {
                [self relaxProtectionAtPath:liveAkc];
                break;
            }
        }
        // Pending pointer for tweak (world-readable under /var/jb/Library/NewDevice)
        NSString *pendingDir = [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-akc"];
        [fm createDirectoryAtPath:pendingDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *akcForPending = [fm fileExistsAtPath:liveAkc] ? liveAkc : nil;
        if (!akcForPending.length) {
            for (NSString *rel in @[@"akc.plist", @"Documents/akc.plist", @"keychain-full.plist"]) {
                NSString *p = [backupRoot stringByAppendingPathComponent:rel];
                if ([fm fileExistsAtPath:p]) { akcForPending = p; break; }
            }
        }
        if (akcForPending.length) {
            NSString *pendingFile = [pendingDir stringByAppendingPathComponent:[bid stringByAppendingString:@".txt"]];
            [akcForPending writeToFile:pendingFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [NDPaths makePathWorldReadable:pendingFile];
            [NDPaths makePathWorldReadable:pendingDir];
        }
    }

    // Marker so Filza / report can prove live write (not just staging)
    NSString *marker = [liveDocsPath stringByAppendingPathComponent:@"nd-restore-ok.txt"];
    NSString *markText = [NSString stringWithFormat:@"record=%@\nbundle=%@\ntime=%@\nstagedKB=%llu\nkeychain=%@\n",
                          recordName, bid, [NSDate date], staged / 1024, kcStats ?: @"-"];
    [fm createDirectoryAtPath:liveDocsPath withIntermediateDirectories:YES attributes:nil error:nil];
    [markText writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self relaxProtectionAtPath:marker];

    unsigned long long liveDocs = [self byteSizeAtPath:liveDocsPath];
    unsigned long long liveLib = [self byteSizeAtPath:[container stringByAppendingPathComponent:@"Library"]];
    NSString *sqlite = [liveDocsPath stringByAppendingPathComponent:@"Model.sqlite"];
    NSString *prefs = [container stringByAppendingPathComponent:@"Library/Preferences"];
    prefs = [prefs stringByAppendingPathComponent:[bid stringByAppendingString:@".plist"]];
    unsigned long long sqliteSz = [self byteSizeAtPath:sqlite];
    unsigned long long prefsSz = [self byteSizeAtPath:prefs];
    BOOL markerOk = [fm fileExistsAtPath:marker];
    BOOL liveAkcOk = [fm fileExistsAtPath:[liveDocsPath stringByAppendingPathComponent:@"akc.plist"]];
    BOOL verified = markerOk && ((liveDocs + liveLib) >= (staged / 4) || sqliteSz > 0 || prefsSz > 1024);
    [lines addObject:[NSString stringWithFormat:
                      @"%@ %@ → %@\n  staged=%lluKB live Docs+Lib=%lluKB subs=%lu Model.sqlite=%llu prefs=%llu marker=%@ keychainDump=%@ liveAkc=%@\n  keychainWrite: %@\n  说明：%@",
                      verified ? @"OK" : @"WARN",
                      bid, container, staged / 1024, (liveDocs + liveLib) / 1024, (unsigned long)okSubs,
                      sqliteSz, prefsSz, markerOk ? @"yes" : @"no", hasKC ? @"yes" : @"NO", liveAkcOk ? @"yes" : @"NO",
                      kcStats.length ? kcStats : @"none",
                      hasKC ? @"已暂存 akc；daemon SecItem 常写不进 App 组，须打开 App 让插件进程内再写（看 Documents/nd-akc-ok.txt）"
                            : [NSString stringWithFormat:@"此包无 Keychain/akc（%@）", bid]]];
    // Ensure app relaunches from restored files
    [self terminateApps:@[bid]];
    return verified;
}

/// AMG exports per-app keychain as Documents/akc.plist (dict of SecItem-shaped entries).
- (NSArray *)NDKeychainItemsFromAMGAkcDictionary:(NSDictionary *)akc {
    if (![akc isKindOfClass:[NSDictionary class]] || !akc.count) return @[];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:akc.count];
    [akc enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![obj isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *raw = (NSDictionary *)obj;
        NSData *vData = nil;
        id rawV = raw[@"v_Data"];
        if ([rawV isKindOfClass:[NSData class]]) vData = rawV;
        else if ([rawV isKindOfClass:[NSString class]]) {
            vData = [[NSData alloc] initWithBase64EncodedString:rawV options:0];
            if (!vData.length) vData = [rawV dataUsingEncoding:NSUTF8StringEncoding];
        }
        if (!vData.length) return;
        NSString *cls = [raw[@"class"] isKindOfClass:[NSString class]] ? raw[@"class"] : @"genp";
        NSString *outClass = @"generic";
        if ([cls isEqualToString:@"inet"]) outClass = @"internet";
        else if ([cls isEqualToString:@"cert"] || [cls isEqualToString:@"certificate"]) outClass = @"certificate";
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"class"] = outClass;
        if ([raw[@"acct"] isKindOfClass:[NSString class]]) item[@"account"] = raw[@"acct"];
        if ([raw[@"svce"] isKindOfClass:[NSString class]]) item[@"service"] = raw[@"svce"];
        if ([raw[@"agrp"] isKindOfClass:[NSString class]]) item[@"accessGroup"] = raw[@"agrp"];
        if ([raw[@"srvr"] isKindOfClass:[NSString class]]) item[@"server"] = raw[@"srvr"];
        if ([raw[@"path"] isKindOfClass:[NSString class]]) item[@"path"] = raw[@"path"];
        if ([raw[@"labl"] isKindOfClass:[NSString class]]) item[@"label"] = raw[@"labl"];
        else if ([key isKindOfClass:[NSString class]]) item[@"label"] = key;
        if ([raw[@"sync"] isKindOfClass:[NSNumber class]]) item[@"synchronizable"] = raw[@"sync"];
        item[@"data"] = [vData base64EncodedStringWithOptions:0];
        [items addObject:item];
    }];
    return items;
}

- (BOOL)NDBackupDirHasKeychainDump:(NSString *)dir {
    if (!dir.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in @[@"keychain-full.plist", @"keychain-hints.plist", @"akc.plist", @"Documents/akc.plist"]) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:name]]) return YES;
    }
    return NO;
}

- (NSArray *)NDLoadKeychainItemsFromBackupDir:(NSString *)dir {
    if (!dir.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [NSArray arrayWithContentsOfFile:[dir stringByAppendingPathComponent:@"keychain-full.plist"]];
    if ([items isKindOfClass:[NSArray class]] && items.count) return items;
    items = [NSArray arrayWithContentsOfFile:[dir stringByAppendingPathComponent:@"keychain-hints.plist"]];
    if ([items isKindOfClass:[NSArray class]] && items.count) return items;

    for (NSString *rel in @[@"akc.plist", @"Documents/akc.plist"]) {
        NSString *path = [dir stringByAppendingPathComponent:rel];
        if (![fm fileExistsAtPath:path]) continue;
        NSDictionary *akc = [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *converted = [self NDKeychainItemsFromAMGAkcDictionary:akc];
        if (converted.count) return converted;
    }
    return nil;
}

- (void)NDMaterializeKeychainFullFromAMGInAppDir:(NSString *)dstRoot importKeychain:(BOOL)importKC {
    if (!importKC || !dstRoot.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fullDst = [dstRoot stringByAppendingPathComponent:@"keychain-full.plist"];
    // Prefer existing NewDevice dump; otherwise convert AMG akc.plist
    NSArray *existing = [NSArray arrayWithContentsOfFile:fullDst];
    if ([existing isKindOfClass:[NSArray class]] && existing.count) return;

    NSString *akcPath = nil;
    for (NSString *rel in @[@"akc.plist", @"Documents/akc.plist"]) {
        NSString *p = [dstRoot stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:p]) { akcPath = p; break; }
    }
    if (!akcPath) return;
    NSDictionary *akc = [NSDictionary dictionaryWithContentsOfFile:akcPath];
    NSArray *items = [self NDKeychainItemsFromAMGAkcDictionary:akc];
    if (!items.count) return;
    [fm createDirectoryAtPath:dstRoot withIntermediateDirectories:YES attributes:nil error:nil];
    // Keep a copy at app backup root for detection / Filza
    NSString *rootAkc = [dstRoot stringByAppendingPathComponent:@"akc.plist"];
    if (![akcPath isEqualToString:rootAkc] && ![fm fileExistsAtPath:rootAkc]) {
        [fm copyItemAtPath:akcPath toPath:rootAkc error:nil];
    }
    [items writeToFile:fullDst atomically:YES];
    [items writeToFile:[dstRoot stringByAppendingPathComponent:@"keychain-hints.plist"] atomically:YES];
}

- (BOOL)restoreApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName error:(NSError **)error {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"restore record=%@ apps=%lu", recordName, (unsigned long)bundleIds.count]];
    NSString *accessDetail = nil;
    BOOL canAccess = [self canAccessAppContainers:&accessDetail];
    [lines addObject:accessDetail ?: @"Containers access unknown"];
    if (!canAccess) {
        [lines addObject:@"HINT: 本进程无法列出 /var/mobile/Containers/Data/Application。在 iOS18 Dopamine 上必须用 container-manager 等权限签名 App/daemon。请升级本包后注销桌面再试。"];
        [self writeRestoreReport:[lines componentsJoinedByString:@"\n"]];
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"NDAppDataManager" code:42 userInfo:@{
                NSLocalizedDescriptionKey: @"无法访问 App 沙盒目录（iOS18 权限）。请升级 NewDevice 后注销桌面。"
            }];
        }
        return NO;
    }
    NSUInteger ok = 0;
    for (NSString *bid in bundleIds) {
        if ([self restoreOneApp:bid fromRecord:recordName lines:lines missing:missing]) ok++;
    }
    // Write base report first so AppGroup append can extend it
    [self writeRestoreReport:[lines componentsJoinedByString:@"\n"]];
    [self restoreAppGroupsForRecord:recordName];
    // Re-read combined report into lines for identity notes below
    if (self.lastRestoreReport.length) {
        [lines removeAllObjects];
        [lines addObjectsFromArray:[self.lastRestoreReport componentsSeparatedByString:@"\n"]];
    }
    NSString *importNote = [[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"amg-import-note.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:importNote]) {
        NSString *note = [NSString stringWithContentsOfFile:importNote encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [lines addObject:[NSString stringWithFormat:@"WARN identity: %@", note.length ? note : @"faker ciphertext → randomized identity"]];
        // Existing imports created with random spoof: turn spoof off so Venmo session can stick
        if ([note.lowercaseString containsString:@"ciphertext"] || [note.lowercaseString containsString:@"randomized"]) {
            NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:recordName];
            if (p && p.spoofDeviceIdentity) {
                p.spoofDeviceIdentity = NO;
                [[NDRecordStore shared] saveProfile:p error:nil];
                [lines addObject:@"identity: spoofDeviceIdentity=NO (passthrough real device; faker ciphertext)"];
                notify_post([NDNotifyReload UTF8String]);
            }
        }
    }
    [lines addObject:[NSString stringWithFormat:@"done ok=%lu missing=%lu", (unsigned long)ok, (unsigned long)missing.count]];
    [self writeRestoreReport:[lines componentsJoinedByString:@"\n"]];
    if (missing.count && error && !*error) {
        *error = [NSError errorWithDomain:@"NDAppDataManager" code:40 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"以下 App 未安装/无容器：%@\n详情见 Media/NewDevice/last-restore.txt", [missing componentsJoinedByString:@", "]]
        }];
    }
    return YES;
}

- (BOOL)restoreAllStagedAppsFromRecord:(NSString *)recordName error:(NSError **)error {
    return [self restoreAllStagedAppsFromRecord:recordName onlyBundleIds:nil error:error];
}

- (BOOL)restoreAllStagedAppsFromRecord:(NSString *)recordName
                        onlyBundleIds:(NSArray<NSString *> *)only
                                error:(NSError **)error {
    if (!recordName.length || [recordName isEqualToString:@"原始机器"]) return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appsRoot = [[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"apps"];
    NSArray *entries = [fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
    NSMutableOrderedSet *bids = [NSMutableOrderedSet orderedSet];
    for (NSString *e in entries) {
        if ([e hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[appsRoot stringByAppendingPathComponent:e] isDirectory:&isDir] && isDir) {
            [bids addObject:e];
        }
    }
    // selectApp ids — always include so holographicSourceDir can fall back to /var/mobile/AMG live
    NSArray *selectApps = [NSArray arrayWithContentsOfFile:[[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"selectApp.plist"]];
    if (![selectApps isKindOfClass:[NSArray class]]) selectApps = @[];
    for (id item in selectApps) {
        if ([item isKindOfClass:[NSString class]] && [item length]) [bids addObject:item];
    }
    for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:recordName] ?: @[]) {
        if (b.length) [bids addObject:b];
    }
    // Scan classic AMG live tree for bundle-id folders when staging was wiped by a bad backup
    NSString *recDir = [NDPaths recordDir:recordName];
    NSString *livePath = [[NSString stringWithContentsOfFile:[recDir stringByAppendingPathComponent:@"amg-live-path.txt"]
                                                    encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!livePath.length) {
        NSString *liveName = [[NSString stringWithContentsOfFile:[recDir stringByAppendingPathComponent:@"amg-live-name.txt"]
                                                        encoding:NSUTF8StringEncoding error:nil]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (liveName.length) livePath = [@"/var/mobile/AMG" stringByAppendingPathComponent:liveName];
    }
    if (livePath.length) {
        for (NSString *e in ([fm contentsOfDirectoryAtPath:livePath error:nil] ?: @[])) {
            if ([e hasPrefix:@"."] || [e isEqualToString:@"AppGroup"] || [e isEqualToString:@"Pasteboard"]) continue;
            if (![e containsString:@"."]) continue; // bundle ids look like a.b.c
            BOOL isDir = NO;
            NSString *p = [livePath stringByAppendingPathComponent:e];
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) [bids addObject:e];
        }
    }
    if (only.count) {
        NSSet *filter = [NSSet setWithArray:only];
        NSMutableOrderedSet *filtered = [NSMutableOrderedSet orderedSet];
        for (NSString *b in bids) {
            if ([filter containsObject:b]) [filtered addObject:b];
        }
        // Still try selected targets even if discovery missed them (restoreApps no-ops if empty).
        for (NSString *b in only) {
            if ([b isKindOfClass:[NSString class]] && b.length) [filtered addObject:b];
        }
        bids = filtered;
    } else if (!bids.count) {
        [bids addObject:@"net.kortina.labs.Venmo"];
    }
    return [self restoreApps:bids.array fromRecord:recordName error:error];
}

- (NSString *)syncInjectFilterWithTargetApps:(NSArray<NSString *> *)bundleIds {
    NSMutableOrderedSet *bundles = [NSMutableOrderedSet orderedSetWithObject:@"com.apple.springboard"];
    NSMutableOrderedSet *targets = [NSMutableOrderedSet orderedSet];
    for (NSString *b in bundleIds ?: @[]) {
        if (![b isKindOfClass:[NSString class]] || !b.length) continue;
        if ([b isEqualToString:@"com.local.newdevice"]) continue;
        [bundles addObject:b];
        [targets addObject:b];
    }
    NSDictionary *plist = @{
        @"Filter": @{
            @"Bundles": bundles.array,
            @"Executables": @[ @"CommCenter", @"CommCenterRootHelper" ],
            @"RejectList": @[
                @"com.local.newdevice",
                @"xyz.willy.Sileo",
                @"org.coolstar.SileoStore",
                @"com.saurik.Cydia",
                @"xyz.willy.Zebra",
                @"com.opa334.Dopamine",
                @"com.opa334.TrollStore",
            ],
        },
    };
    NSArray *paths = @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NewDevice.plist",
        @"/var/jb/usr/lib/TweakInject/NewDevice.plist",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"bundles=%lu %@", (unsigned long)bundles.count,
                      [bundles.array componentsJoinedByString:@","]]];
    for (NSString *path in paths) {
        NSString *off = [path stringByAppendingString:@".off"];
        NSString *writePath = path;
        if (![fm fileExistsAtPath:path] && [fm fileExistsAtPath:off]) writePath = off;
        if (![fm fileExistsAtPath:writePath] && ![fm fileExistsAtPath:[writePath stringByDeletingLastPathComponent]]) {
            [lines addObject:[NSString stringWithFormat:@"skip %@", writePath]];
            continue;
        }
        BOOL ok = [plist writeToFile:writePath atomically:YES];
        if (!ok) {
            // Non-atomic fallback (some rootless mounts reject rename-into-place).
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                      format:NSPropertyListXMLFormat_v1_0
                                                                     options:0
                                                                       error:nil];
            ok = data && [data writeToFile:writePath atomically:NO];
        }
        NSError *attrErr = nil;
        [[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: @(0644) }
                                         ofItemAtPath:writePath error:&attrErr];
        [lines addObject:[NSString stringWithFormat:@"%@ %@%@",
                          ok ? @"ok" : @"fail", writePath,
                          ok ? @"" : @" (need root daemon / postinst sync-inject)"]];
        if (ok) [NDPaths makePathWorldReadable:writePath];
    }

    // Sole-owner inject: NewDevice target apps must not also load amg.dylib
    // (crash corpus: every Venmo IPS had NewDevice+amg; UIDevice.systemVersion→MG PAC).
    // ElleKit: empty Filter.Bundles often means "inject ALL apps" — RejectList alone is NOT enough.
    NSArray *amgPaths = @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/amg.plist",
        @"/var/jb/usr/lib/TweakInject/amg.plist",
    ];
    for (NSString *amgPath in amgPaths) {
        if (![fm fileExistsAtPath:amgPath]) {
            [lines addObject:[NSString stringWithFormat:@"amg-miss %@", amgPath]];
            continue;
        }
        NSMutableDictionary *amg = [[NSDictionary dictionaryWithContentsOfFile:amgPath] mutableCopy];
        if (![amg isKindOfClass:[NSMutableDictionary class]]) {
            [lines addObject:[NSString stringWithFormat:@"amg-bad %@", amgPath]];
            continue;
        }
        // Dump pre-fix for Media debugging
        @try {
            NSString *dump = [NSString stringWithFormat:@"/var/mobile/Media/NewDevice/amg-filter-dump-%@.plist",
                              [[amgPath lastPathComponent] stringByDeletingPathExtension]];
            [amg writeToFile:dump atomically:YES];
        } @catch (__unused NSException *ex) {}

        NSMutableDictionary *filter = [amg[@"Filter"] isKindOfClass:[NSDictionary class]]
            ? [amg[@"Filter"] mutableCopy]
            : [NSMutableDictionary dictionary];
        NSMutableArray *amgBundles = [filter[@"Bundles"] isKindOfClass:[NSArray class]]
            ? [filter[@"Bundles"] mutableCopy]
            : [NSMutableArray array];
        NSMutableOrderedSet *reject = [NSMutableOrderedSet orderedSet];
        if ([filter[@"RejectList"] isKindOfClass:[NSArray class]]) {
            [reject addObjectsFromArray:filter[@"RejectList"]];
        }
        NSUInteger removed = 0;
        for (NSString *bid in targets.array) {
            while ([amgBundles containsObject:bid]) {
                [amgBundles removeObject:bid];
                removed++;
            }
            [reject addObject:bid];
        }
        // Critical: never leave Bundles empty while we need to spare targets.
        // Scope AMG to its own app only so Venmo/Safari/etc. are not injected.
        if (targets.count > 0) {
            if (amgBundles.count == 0) {
                [amgBundles addObject:@"com.superdev.AMG"];
            }
            // Also strip common wildcards if present
            [amgBundles removeObject:@"*"];
            [amgBundles removeObject:@"**"];
        }
        filter[@"Bundles"] = amgBundles;
        filter[@"RejectList"] = reject.array;
        amg[@"Filter"] = filter;
        BOOL ok = [amg writeToFile:amgPath atomically:YES];
        if (!ok) {
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:amg
                                                                      format:NSPropertyListXMLFormat_v1_0
                                                                     options:0
                                                                       error:nil];
            ok = data && [data writeToFile:amgPath atomically:NO];
        }
        if (ok) [NDPaths makePathWorldReadable:amgPath];
        [lines addObject:[NSString stringWithFormat:@"amg-%@ %@ removed=%lu bundles=%lu reject=%lu%@",
                          ok ? @"ok" : @"fail", amgPath,
                          (unsigned long)removed, (unsigned long)amgBundles.count,
                          (unsigned long)reject.count,
                          ok ? @"" : @" (need root)"]];
        // Post-fix dump
        @try {
            NSString *dump2 = @"/var/mobile/Media/NewDevice/amg-filter-after.plist";
            [amg writeToFile:dump2 atomically:YES];
        } @catch (__unused NSException *ex) {}
    }

    // Hard fallback: if targets are set, rename amg.dylib so ElleKit cannot load it into those apps.
    // Restored automatically when sync runs with empty targets (not done here — user re-enables AMG in Sileo).
    if (targets.count > 0) {
        NSArray *dylibs = @[
            @"/var/jb/Library/MobileSubstrate/DynamicLibraries/amg.dylib",
            @"/var/jb/usr/lib/TweakInject/amg.dylib",
        ];
        for (NSString *dy in dylibs) {
            NSString *off = [dy stringByAppendingString:@".nd-off"];
            if ([fm fileExistsAtPath:dy] && ![fm fileExistsAtPath:off]) {
                NSError *err = nil;
                BOOL mov = [fm moveItemAtPath:dy toPath:off error:&err];
                [lines addObject:[NSString stringWithFormat:@"amg-dylib-%@ %@%@",
                                  mov ? @"off" : @"fail", dy,
                                  err ? [NSString stringWithFormat:@" (%@)", err.localizedDescription] : @""]];
            } else if ([fm fileExistsAtPath:off]) {
                [lines addObject:[NSString stringWithFormat:@"amg-dylib-already-off %@", off]];
            } else {
                [lines addObject:[NSString stringWithFormat:@"amg-dylib-miss %@", dy]];
            }
        }
    }

    NSString *report = [lines componentsJoinedByString:@"\n"];
    [report writeToFile:@"/var/mobile/Media/NewDevice/last-inject-filter.txt"
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[NewDevice] syncInjectFilter %@", report);
    return report;
}

- (BOOL)backupKeychainHintsForApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName {
    // Fuller dump: generic + internet passwords (+ optional cert/key metadata) across access groups.
    for (NSString *bid in bundleIds) {
        NSMutableArray *items = [NSMutableArray array];
        NSArray *classes = @[
            (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecClassInternetPassword,
        ];
        for (id secClass in classes) {
            NSMutableDictionary *query = [@{
                (__bridge id)kSecClass: secClass,
                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                (__bridge id)kSecReturnAttributes: @YES,
                (__bridge id)kSecReturnData: @YES,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
            } mutableCopy];
            CFTypeRef result = NULL;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
            if (status != errSecSuccess || !result) {
                if (result) CFRelease(result);
                continue;
            }
            NSArray *arr = (__bridge_transfer NSArray *)result;
            for (NSDictionary *item in arr) {
                NSString *service = item[(__bridge id)kSecAttrService] ?: @"";
                NSString *account = item[(__bridge id)kSecAttrAccount] ?: @"";
                NSString *accessGroup = item[(__bridge id)kSecAttrAccessGroup] ?: @"";
                NSString *server = item[(__bridge id)kSecAttrServer] ?: @"";
                NSString *label = item[(__bridge id)kSecAttrLabel] ?: @"";
                BOOL related = [service containsString:bid]
                    || [account containsString:bid]
                    || [accessGroup containsString:bid]
                    || [server containsString:bid]
                    || [label containsString:bid];
                if (!related && [accessGroup hasPrefix:@"group."]) {
                    NSString *tail = bid.lastPathComponent ?: bid;
                    related = [accessGroup.lowercaseString containsString:tail.lowercaseString];
                }
                // Also keep items whose access group matches app's known groups via heuristic last path
                if (!related && bid.pathExtension.length) {
                    NSString *tail = bid.pathExtension;
                    related = [accessGroup containsString:tail] || [service containsString:tail];
                }
                if (!related) continue;

                NSMutableDictionary *copy = [NSMutableDictionary dictionary];
                copy[@"class"] = [secClass isEqual:(__bridge id)kSecClassInternetPassword] ? @"internet" : @"generic";
                copy[@"service"] = service;
                copy[@"account"] = account;
                if (accessGroup.length) copy[@"accessGroup"] = accessGroup;
                if (server.length) copy[@"server"] = server;
                if (label.length) copy[@"label"] = label;
                id protocol = item[(__bridge id)kSecAttrProtocol];
                if (protocol) copy[@"protocol"] = [protocol description];
                id port = item[(__bridge id)kSecAttrPort];
                if (port) copy[@"port"] = port;
                id path = item[(__bridge id)kSecAttrPath];
                if ([path isKindOfClass:[NSString class]]) copy[@"path"] = path;
                id sync = item[(__bridge id)kSecAttrSynchronizable];
                if (sync) copy[@"synchronizable"] = @([sync boolValue]);
                id accessible = item[(__bridge id)kSecAttrAccessible];
                if (accessible) copy[@"accessible"] = [accessible description];
                NSData *data = item[(__bridge id)kSecValueData];
                if (data) copy[@"data"] = [data base64EncodedStringWithOptions:0];
                [items addObject:copy];
            }
        }

        // Also try certificates tied to the bundle (DER when exportable)
        {
            NSDictionary *query = @{
                (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                (__bridge id)kSecReturnAttributes: @YES,
                (__bridge id)kSecReturnData: @YES,
            };
            CFTypeRef result = NULL;
            if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess && result) {
                NSArray *arr = (__bridge_transfer NSArray *)result;
                for (NSDictionary *item in arr) {
                    NSString *label = item[(__bridge id)kSecAttrLabel] ?: @"";
                    NSString *accessGroup = item[(__bridge id)kSecAttrAccessGroup] ?: @"";
                    if (![label containsString:bid] && ![accessGroup containsString:bid]) continue;
                    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
                    copy[@"class"] = @"certificate";
                    copy[@"label"] = label;
                    if (accessGroup.length) copy[@"accessGroup"] = accessGroup;
                    NSData *der = item[(__bridge id)kSecValueData];
                    if ([der isKindOfClass:[NSData class]] && der.length) {
                        copy[@"data"] = [der base64EncodedStringWithOptions:0];
                    }
                    [items addObject:copy];
                }
            } else if (result) {
                CFRelease(result);
            }
        }

        NSString *dir = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        // Keep legacy filename for older records + richer dump
        [items writeToFile:[dir stringByAppendingPathComponent:@"keychain-hints.plist"] atomically:YES];
        [items writeToFile:[dir stringByAppendingPathComponent:@"keychain-full.plist"] atomically:YES];
    }
    return YES;
}

- (NSString *)restoreKeychainHintsForApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName {
    // CRITICAL (iOS 18): never SecItemAdd/Delete from newdeviced into app access groups.
    // Daemon has keychain-access-groups=* and previously scanned/wrote globally-visible items,
    // which can leave Venmo unable to launch even after reinstall. In-app KeychainRestore.x
    // is the only safe writer; here we only stage akc.plist into the live Documents folder.
    NSMutableArray *parts = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *bid in bundleIds) {
        NSString *dir = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
        [self NDMaterializeKeychainFullFromAMGInAppDir:dir importKeychain:YES];
        NSString *srcAkc = nil;
        for (NSString *rel in @[@"Documents/akc.plist", @"akc.plist"]) {
            NSString *p = [dir stringByAppendingPathComponent:rel];
            if ([fm fileExistsAtPath:p]) { srcAkc = p; break; }
        }
        if (!srcAkc.length) {
            NSString *note = nil;
            NSString *holo = [self holographicSourceDirForBundleId:bid recordName:recordName sourceNote:&note];
            if (holo.length) {
                for (NSString *rel in @[@"Documents/akc.plist", @"akc.plist"]) {
                    NSString *p = [holo stringByAppendingPathComponent:rel];
                    if ([fm fileExistsAtPath:p]) { srcAkc = p; break; }
                }
            }
        }
        NSString *live = [self containerPathForBundleId:bid];
        NSString *liveAkc = live.length
            ? [[live stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"akc.plist"]
            : nil;
        BOOL copied = NO;
        if (srcAkc.length && liveAkc.length) {
            [fm createDirectoryAtPath:[liveAkc stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:liveAkc error:nil];
            copied = [fm copyItemAtPath:srcAkc toPath:liveAkc error:nil];
        }
        // Pending pointer for in-app restore (jb + Media — Venmo may only see Media)
        if (srcAkc.length) {
            for (NSString *pendingDir in @[
                     [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-akc"],
                     @"/var/mobile/Media/NewDevice/pending-akc",
                 ]) {
                [fm createDirectoryAtPath:pendingDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *pending = [pendingDir stringByAppendingPathComponent:[bid stringByAppendingString:@".txt"]];
                // Prefer live Documents path when available so in-app restore reads sandboxed file
                NSString *ptr = (liveAkc.length && [fm fileExistsAtPath:liveAkc]) ? liveAkc : srcAkc;
                [ptr writeToFile:pending atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [NDPaths makePathWorldReadable:pending];
                [NDPaths makePathWorldReadable:pendingDir];
            }
        }
        [parts addObject:[NSString stringWithFormat:@"%@: daemonKeychain=SKIP stagedAkc=%@ liveAkc=%@",
                          bid, srcAkc.length ? @"yes" : @"no", copied ? @"copied" : (liveAkc.length && [fm fileExistsAtPath:liveAkc] ? @"present" : @"missing")]];
    }
    return parts.count ? [parts componentsJoinedByString:@"; "] : @"none";
}

- (NSString *)clearKeychainAccessGroupForBundleId:(NSString *)bundleId {
    if (!bundleId.length) return @"missing bundleId";
    NSString *agrp = [self defaultKeychainAccessGroupForBundleId:bundleId];
    if (!agrp.length) return [NSString stringWithFormat:@"%@: no agrp", bundleId];
    return [self NDClearKeychainAccessGroup:agrp bundleId:bundleId];
}

- (NSString *)NDClearKeychainAccessGroup:(NSString *)agrp bundleId:(NSString *)bundleId {
    if (!agrp.length) return @"missing agrp";
    NSUInteger deleted = 0;
    NSMutableArray *notes = [NSMutableArray array];
    for (id secClass in @[ (__bridge id)kSecClassGenericPassword,
                           (__bridge id)kSecClassInternetPassword,
                           (__bridge id)kSecClassCertificate,
                           (__bridge id)kSecClassKey,
                           (__bridge id)kSecClassIdentity ]) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecAttrAccessGroup: agrp,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
        };
        CFTypeRef result = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (st == errSecItemNotFound) continue;
        if (st != errSecSuccess || !result) {
            if (result) CFRelease(result);
            if (notes.count < 4) [notes addObject:[NSString stringWithFormat:@"query=%d", (int)st]];
            continue;
        }
        NSArray *arr = (__bridge_transfer NSArray *)result;
        for (NSDictionary *item in arr) {
            NSMutableDictionary *del = [@{ (__bridge id)kSecClass: secClass,
                                           (__bridge id)kSecAttrAccessGroup: agrp } mutableCopy];
            id acct = item[(__bridge id)kSecAttrAccount];
            id svce = item[(__bridge id)kSecAttrService];
            id srvr = item[(__bridge id)kSecAttrServer];
            id lab = item[(__bridge id)kSecAttrLabel];
            if ([acct isKindOfClass:[NSString class]] && [acct length]) del[(__bridge id)kSecAttrAccount] = acct;
            if ([svce isKindOfClass:[NSString class]] && [svce length]) del[(__bridge id)kSecAttrService] = svce;
            if ([srvr isKindOfClass:[NSString class]] && [srvr length]) del[(__bridge id)kSecAttrServer] = srvr;
            if ([lab isKindOfClass:[NSString class]] && [lab length]) del[(__bridge id)kSecAttrLabel] = lab;
            if (SecItemDelete((__bridge CFDictionaryRef)del) == errSecSuccess) deleted++;
        }
    }
    NSString *line = [NSString stringWithFormat:@"%@ agrp=%@ deleted=%lu%@",
                      bundleId.length ? bundleId : @"?", agrp, (unsigned long)deleted,
                      notes.count ? [NSString stringWithFormat:@" notes=%@", [notes componentsJoinedByString:@","]] : @""];
    NSLog(@"[NewDevice] clearKeychain %@", line);
    [line writeToFile:@"/var/mobile/Media/NewDevice/last-keychain-clear.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return line;
}

- (NSString *)purgeVenmoSessionInApp {
    NSString *vbid = @"net.kortina.labs.Venmo";
    NSMutableArray *lines = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    [self terminateApps:@[vbid]];
    [self clearDataForApps:@[vbid] error:nil];
    [lines addObject:@"sandbox=wiped"];

    // Drop any pending restore so we don't re-add the old session.
    for (NSString *p in @[
             [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-akc/net.kortina.labs.Venmo.txt"],
             @"/var/mobile/Media/NewDevice/pending-akc/net.kortina.labs.Venmo.txt",
         ]) {
        if ([fm fileExistsAtPath:p]) {
            [fm removeItemAtPath:p error:nil];
            [lines addObject:[@"removed " stringByAppendingString:p.lastPathComponent]];
        }
    }

    // Best-effort outside clear (usually deletes 0 on iOS 18 — Venmo partition).
    NSString *outside = [self NDClearKeychainAccessGroup:@"55377VK7X2.net.kortina.labs.Venmo" bundleId:vbid];
    [lines addObject:[@"outside " stringByAppendingString:outside ?: @""]];
    outside = [self NDClearKeychainAccessGroup:@"6DEPQ9SPDK.net.kortina.labs.Venmo" bundleId:vbid];
    [lines addObject:[@"outside " stringByAppendingString:outside ?: @""]];

    // Stage in-app clear flag (Venmo tweak reads these paths).
    for (NSString *dir in @[
             [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-clear-kc"],
             @"/var/mobile/Media/NewDevice/pending-clear-kc",
         ]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *flag = [dir stringByAppendingPathComponent:vbid];
        [@"1" writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NDPaths makePathWorldReadable:flag];
        [NDPaths makePathWorldReadable:dir];
    }
    [lines addObject:@"pending-clear-kc=staged"];

    // Remove stale result so we can detect a fresh write.
    for (NSString *p in @[
             @"/var/jb/Library/NewDevice/last-venmo-kc-clear.txt",
             @"/var/mobile/Media/NewDevice/last-venmo-kc-clear.txt",
         ]) {
        [fm removeItemAtPath:p error:nil];
    }

    // Launch Venmo for in-app clear without leaving old-session UI on screen.
    [lines addObject:[self NDLaunchVenmoForKeychainWork] ?: @"launch=failed"];

    BOOL cleared = NO;
    for (NSInteger i = 0; i < 14; i++) { // ~3.5s (was ~20s)
        [NSThread sleepForTimeInterval:0.25];
        NSString *body = [NSString stringWithContentsOfFile:@"/var/mobile/Media/NewDevice/last-venmo-kc-clear.txt"
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (!body.length) {
            body = [NSString stringWithContentsOfFile:@"/var/jb/Library/NewDevice/last-venmo-kc-clear.txt"
                                             encoding:NSUTF8StringEncoding error:nil];
        }
        if (body.length && [body containsString:@"in-app-clear"]) {
            cleared = YES;
            [lines addObject:[NSString stringWithFormat:@"in-app-clear OK t=%.2fs", (i + 1) * 0.25]];
            [lines addObject:body];
            break;
        }
    }
    if (!cleared) [lines addObject:@"in-app-clear TIMEOUT — open Venmo once manually, then retry"];

    [self terminateApps:@[vbid]];
    [self clearDataForApps:@[vbid] error:nil];
    [lines addObject:@"sandbox=rewiped"];
    // Stay on NewDevice after background Venmo work.
    [self NDOpenBundleId:NDBundleID];

    NSString *report = [lines componentsJoinedByString:@"\n"];
    [report writeToFile:@"/var/mobile/Media/NewDevice/last-keychain-clear.txt"
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return report;
}

- (NSString *)clearVenmoKeychainAllKnownGroups {
    // Daemon/App SecItem cannot see Venmo's keychain partition on iOS 18 — that is why
    // uninstall+redownload still auto-logs into the old account. Always drive in-app clear.
    return [self purgeVenmoSessionInApp];
}

- (void)NDStageVenmoPendingClearFlag {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *vbid = @"net.kortina.labs.Venmo";
    for (NSString *dir in @[
             [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-clear-kc"],
             @"/var/mobile/Media/NewDevice/pending-clear-kc",
         ]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *flag = [dir stringByAppendingPathComponent:vbid];
        [@"1" writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NDPaths makePathWorldReadable:flag];
        [NDPaths makePathWorldReadable:dir];
    }
}

/// Wipe Venmo sandbox + stage in-app clear for next open — do NOT launch Venmo (no flash).
- (NSString *)stageVenmoSessionClearOnly {
    NSString *vbid = @"net.kortina.labs.Venmo";
    [self terminateApps:@[vbid]];
    [self clearDataForApps:@[vbid] error:nil];
    for (NSString *p in @[
             [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-akc/net.kortina.labs.Venmo.txt"],
             @"/var/mobile/Media/NewDevice/pending-akc/net.kortina.labs.Venmo.txt",
         ]) {
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    }
    [self NDStageVenmoPendingClearFlag];
    NSString *report = @"venmo=staged-clear-no-launch";
    [report writeToFile:@"/var/mobile/Media/NewDevice/last-keychain-clear.txt"
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return report;
}

- (NSString *)bindVenmoKeychainToCurrentRecord {
    // Environment isolation: drop previous Venmo session tokens, then apply this record's akc.
    NSString *vbid = @"net.kortina.labs.Venmo";
    NSMutableArray *lines = [NSMutableArray array];
    NSString *rec = [[NDRecordStore shared] currentRecordName] ?: @"";
    [lines addObject:[NSString stringWithFormat:@"record=%@", rec.length ? rec : @"(none)"]];

    [self terminateApps:@[vbid]];
    [self NDStageVenmoPendingClearFlag];
    [lines addObject:@"pending-clear-kc=staged"];

    // Ensure live Documents has akc + pending-akc for this record.
    if (rec.length && ![rec isEqualToString:@"原始机器"]) {
        NSString *kc = [self restoreKeychainHintsForApps:@[vbid] fromRecord:rec];
        [lines addObject:kc ?: @"akc=missing"];
    }

    for (NSString *p in @[
             @"/var/jb/Library/NewDevice/last-venmo-kc-clear.txt",
             @"/var/mobile/Media/NewDevice/last-venmo-kc-clear.txt",
         ]) {
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    }
    NSString *live = [self containerPathForBundleId:vbid];
    NSString *akcOk = live.length
        ? [[live stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"nd-akc-ok.txt"]
        : nil;
    if (akcOk.length) [[NSFileManager defaultManager] removeItemAtPath:akcOk error:nil];

    [lines addObject:[self NDLaunchVenmoForKeychainWork] ?: @"launch=failed"];

    BOOL cleared = NO, restored = NO;
    for (NSInteger i = 0; i < 16; i++) { // ~4s (was ~25s)
        [NSThread sleepForTimeInterval:0.25];
        NSString *clr = [NSString stringWithContentsOfFile:@"/var/mobile/Media/NewDevice/last-venmo-kc-clear.txt"
                                                  encoding:NSUTF8StringEncoding error:nil];
        if (!clr.length) {
            clr = [NSString stringWithContentsOfFile:@"/var/jb/Library/NewDevice/last-venmo-kc-clear.txt"
                                            encoding:NSUTF8StringEncoding error:nil];
        }
        if (!cleared && clr.length && [clr containsString:@"in-app-clear"]) {
            cleared = YES;
            [lines addObject:[NSString stringWithFormat:@"clear OK t=%.2fs", (i + 1) * 0.25]];
        }
        if (akcOk.length) {
            NSString *ok = [NSString stringWithContentsOfFile:akcOk encoding:NSUTF8StringEncoding error:nil];
            if (ok.length && [ok containsString:@"ok="] && ![ok containsString:@"ok=0"]) {
                restored = YES;
                [lines addObject:[NSString stringWithFormat:@"akc OK t=%.2fs", (i + 1) * 0.25]];
                break;
            }
        }
        if (cleared && restored) break;
        if (cleared && !akcOk.length && i >= 4) break;
        if (cleared && i >= 10) break; // leave pending-akc for next manual open
    }
    if (!cleared) [lines addObject:@"clear TIMEOUT"];
    if (!restored) [lines addObject:@"akc TIMEOUT — pending-akc kept for next open"];

    [self terminateApps:@[vbid]];
    // Skip full sandbox reapply (slow). Files already restored before bind.
    for (NSString *p in @[
             [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-akc/net.kortina.labs.Venmo.txt"],
             @"/var/mobile/Media/NewDevice/pending-akc/net.kortina.labs.Venmo.txt",
         ]) {
        if (restored) [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    }
    for (NSString *dir in @[
             [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"pending-clear-kc"],
             @"/var/mobile/Media/NewDevice/pending-clear-kc",
         ]) {
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:vbid] error:nil];
    }
    if (cleared || restored) [lines addObject:@"sandbox=keep-prebind"];
    [self NDOpenBundleId:NDBundleID];
    NSString *report = [lines componentsJoinedByString:@"\n"];
    [report writeToFile:@"/var/mobile/Media/NewDevice/last-venmo-bind.txt"
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return report;
}

- (NSString *)setTweakInjectionEnabled:(BOOL)enabled {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *pairs = @[
        @[ @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NewDevice.dylib",
           @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NewDevice.dylib.off" ],
        @[ @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NewDevice.plist",
           @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NewDevice.plist.off" ],
        @[ @"/var/jb/usr/lib/TweakInject/NewDevice.dylib",
           @"/var/jb/usr/lib/TweakInject/NewDevice.dylib.off" ],
        @[ @"/var/jb/usr/lib/TweakInject/NewDevice.plist",
           @"/var/jb/usr/lib/TweakInject/NewDevice.plist.off" ],
    ];
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"setTweakInjectionEnabled=%@", enabled ? @"YES" : @"NO"]];
    for (NSArray *pair in pairs) {
        NSString *on = pair[0];
        NSString *off = pair[1];
        NSString *from = enabled ? off : on;
        NSString *to = enabled ? on : off;
        if (![fm fileExistsAtPath:from]) {
            [lines addObject:[NSString stringWithFormat:@"skip missing %@", from]];
            continue;
        }
        [fm removeItemAtPath:to error:nil];
        NSError *err = nil;
        BOOL ok = [fm moveItemAtPath:from toPath:to error:&err];
        [lines addObject:[NSString stringWithFormat:@"%@ %@ → %@%@",
                          ok ? @"OK" : @"FAIL", from, to,
                          err ? [NSString stringWithFormat:@" (%@)", err.localizedDescription] : @""]];
    }
    NSString *body = [lines componentsJoinedByString:@"\n"];
    [body writeToFile:@"/var/mobile/Media/NewDevice/last-tweak-toggle.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return body;
}

- (NSString *)clearElleKitSafeMode {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        @"/var/mobile/.eksafemode",
        @"/var/jb/var/mobile/.eksafemode",
        @"/var/mobile/Library/Preferences/.eksafemode",
        @"/var/root/.eksafemode",
    ];
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:@"clearElleKitSafeMode"];
    for (NSString *p in paths) {
        if (![fm fileExistsAtPath:p]) {
            [lines addObject:[NSString stringWithFormat:@"MISS %@", p]];
            continue;
        }
        NSError *err = nil;
        BOOL ok = [fm removeItemAtPath:p error:&err];
        [lines addObject:[NSString stringWithFormat:@"%@ %@%@",
                          ok ? @"DEL" : @"FAIL", p,
                          err ? [NSString stringWithFormat:@" (%@)", err.localizedDescription] : @""]];
    }
    NSString *body = [lines componentsJoinedByString:@"\n"];
    [body writeToFile:@"/var/mobile/Media/NewDevice/last-safemode-clear.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm createDirectoryAtPath:@"/var/jb/Library/NewDevice" withIntermediateDirectories:YES attributes:nil error:nil];
    [body writeToFile:@"/var/jb/Library/NewDevice/last-safemode-clear.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return body;
}

- (NSString *)respringSpringBoard {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        pid_t pid = 0;
        char *argv[] = { "/var/jb/usr/bin/killall", "-9", "SpringBoard", NULL };
        if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0) {
            char *argv2[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
            posix_spawn(&pid, argv2[0], NULL, NULL, argv2, environ);
        }
    });
    return @"respring scheduled";
}

- (NSString *)installDebAtPath:(NSString *)path {
    NSMutableArray *lines = [NSMutableArray array];
    if (!path.length) {
        // Prefer staged upgrade packages under Media/NewDevice
        NSArray *cands = @[
            @"/var/mobile/Media/NewDevice/NewDevice-1.0.0-207.deb",
            @"/var/mobile/Media/Downloads/NewDevice-1.0.0-207.deb",
            @"/var/mobile/Media/NewDevice/NewDevice-1.0.0-206.deb",
            @"/var/mobile/Media/Downloads/NewDevice-1.0.0-206.deb",
            @"/var/mobile/Media/NewDevice/NewDevice-1.0.0-205.deb",
            @"/var/mobile/Media/Downloads/NewDevice-1.0.0-205.deb",
            @"/var/mobile/Library/Logs/CrashReporter/NewDevice-1.0.0-205.deb",
            @"/var/mobile/Media/NewDevice/NewDevice.deb",
            @"/var/mobile/Media/Downloads/NewDevice.deb",
        ];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *c in cands) {
            if ([fm fileExistsAtPath:c]) { path = c; break; }
        }
    }
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return @"FAIL missing deb (place NewDevice-*.deb under /var/mobile/Media/NewDevice/)";
    }
    [lines addObject:[NSString stringWithFormat:@"deb=%@", path]];

    // Prefer absolute dpkg; fall back to apt-get install.
    NSArray *attempts = @[
        @[ @"/var/jb/usr/bin/dpkg", @"-i", path ],
        @[ @"/usr/bin/dpkg", @"-i", path ],
        @[ @"/var/jb/usr/bin/apt-get", @"install", @"-y", path ],
        @[ @"/var/jb/basebin/jbctl", @"internal", @"launch_daemons" ], // touch only; real install above
    ];
    BOOL anySpawn = NO;
    for (NSArray *args in attempts) {
        if (args.count < 2) continue;
        NSString *bin = args[0];
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
            [lines addObject:[NSString stringWithFormat:@"skip missing %@", bin]];
            continue;
        }
        // Skip jbctl placeholder
        if ([bin containsString:@"jbctl"]) continue;

        pid_t pid = 0;
        char **argv = calloc(args.count + 1, sizeof(char *));
        for (NSUInteger i = 0; i < args.count; i++) {
            argv[i] = (char *)[args[i] UTF8String];
        }
        argv[args.count] = NULL;
        int rc = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
        free(argv);
        [lines addObject:[NSString stringWithFormat:@"spawn %@ rc=%d pid=%d", bin, rc, (int)pid]];
        if (rc == 0) {
            anySpawn = YES;
            int status = 0;
            waitpid(pid, &status, 0);
            [lines addObject:[NSString stringWithFormat:@"wait status=%d", status]];
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                [lines addObject:@"OK installed"];
                break;
            }
        }
    }
    if (!anySpawn) [lines addObject:@"FAIL no dpkg/apt executable spawned (need root daemon)"];

    // After success, sync inject filter (exclude Venmo from amg).
    @try {
        [[NDConfig shared] reload];
        NSArray *targets = [NDConfig shared].targetApps ?: @[ @"net.kortina.labs.Venmo" ];
        NSString *sync = [self syncInjectFilterWithTargetApps:targets];
        if (sync.length) [lines addObject:sync];
    } @catch (__unused NSException *ex) {
    }

    NSString *body = [lines componentsJoinedByString:@"\n"];
    [body writeToFile:@"/var/mobile/Media/NewDevice/last-deb-install.txt"
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return body;
}

- (NSString *)sharedAppGroupPathForGroupId:(NSString *)groupId {
    if (!groupId.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *scanned = [self NDScanContainerUnderRoots:@[
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Shared/AppGroup",
    ] identifier:groupId];
    if (scanned.length) return scanned;

    NSURL *mcm = [self NDMCMContainerURLSafe:groupId classNames:@[
        @"MCMSharedAppGroupContainer",
        @"MCMAppGroupContainer",
        @"MCMSharedDataContainer",
    ]];
    if (mcm.path.length && [fm fileExistsAtPath:mcm.path]) return mcm.path;
    return nil;
}

- (void)backupAppGroupsForBundleId:(NSString *)bid toRecord:(NSString *)recordName {
    if (!bid.length || !recordName.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *agRoot = [[[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"AppGroup"] stringByAppendingPathComponent:bid];

    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy && [LSApplicationProxy respondsToSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id proxy = [LSApplicationProxy performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:bid];
#pragma clang diagnostic pop
        if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"groupContainerURLs")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id groups = [proxy performSelector:NSSelectorFromString(@"groupContainerURLs")];
#pragma clang diagnostic pop
            if ([groups isKindOfClass:[NSDictionary class]]) {
                [(NSDictionary *)groups enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                    NSString *groupId = [key isKindOfClass:[NSString class]] ? key : [key description];
                    NSURL *url = [obj isKindOfClass:[NSURL class]] ? obj : nil;
                    if (!groupId.length || !url.path.length) return;
                    // AMG-like layout: AppGroup/<bid>/<containerUUID>/{Documents,Library,...}
                    NSString *leaf = [agRoot stringByAppendingPathComponent:url.path.lastPathComponent];
                    for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
                        NSString *src = [url.path stringByAppendingPathComponent:sub];
                        if ([fm fileExistsAtPath:src]) {
                            [self copyItem:src to:[leaf stringByAppendingPathComponent:sub] error:nil];
                        }
                    }
                    NSDictionary *hint = @{@"groupId": groupId};
                    [hint writeToFile:[leaf stringByAppendingPathComponent:@"nd-group-id.plist"] atomically:YES];
                }];
                return;
            }
        }
    }
}

- (void)importAMGHolographicFromDirectory:(NSString *)amgRecordDir intoRecord:(NSString *)recordName {
    [self NDImportAMGHolographicFromDirectory:amgRecordDir intoRecord:recordName depth:0];
}

/// Stage AMG holographic app trees. Descends into apps/ and UUID wrappers
/// (AMG_resolved often has AppGroup + apps/ as siblings — old code skipped both).
- (void)NDImportAMGHolographicFromDirectory:(NSString *)amgRecordDir intoRecord:(NSString *)recordName depth:(NSInteger)depth {
    if (!amgRecordDir.length || !recordName.length || depth > 5) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:amgRecordDir error:nil] ?: @[];
    static NSSet *skip;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skip = [NSSet setWithArray:@[@"AppGroup", @"Pasteboard", @"Documents", @"Library", @"tmp", @"SystemData",
                                     @"01_plaintext_identity", @"02_config_plists", @"03_holographic_backups"]];
    });

    BOOL importKC = [NDConfig shared].importKeychainWithData;
    NSMutableArray<NSString *> *descend = [NSMutableArray array];

    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        if ([skip containsObject:entry]) continue;
        if ([entry.pathExtension.lowercaseString isEqualToString:@"plist"]) continue;
        if ([entry.pathExtension.lowercaseString isEqualToString:@"txt"]) continue;
        NSString *srcRoot = [amgRecordDir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:srcRoot isDirectory:&isDir] || !isDir) continue;

        // Bundle-id folders look like com.foo.bar / net.kortina.labs.Venmo
        BOOL looksBid = ([entry rangeOfString:@"."].location != NSNotFound)
            && [entry componentsSeparatedByString:@"."].count >= 2;
        if (looksBid) {
            NSString *dstRoot = [NDPaths appsBackupDirForRecord:recordName bundleId:entry];
            BOOL copiedSub = NO;
            for (NSString *sub in @[@"Documents", @"Library", @"tmp", @"SystemData"]) {
                NSString *src = [srcRoot stringByAppendingPathComponent:sub];
                if (![fm fileExistsAtPath:src]) continue;
                [self copyItem:src to:[dstRoot stringByAppendingPathComponent:sub] error:nil];
                copiedSub = YES;
            }
            // Some AMG dumps put container contents directly under the bid folder
            if (!copiedSub) {
                NSArray *kids = [fm contentsOfDirectoryAtPath:srcRoot error:nil] ?: @[];
                for (NSString *kid in kids) {
                    if ([kid hasPrefix:@"."]) continue;
                    if ([kid.pathExtension.lowercaseString isEqualToString:@"plist"] && [kid.lowercaseString containsString:@"keychain"]) continue;
                    NSString *src = [srcRoot stringByAppendingPathComponent:kid];
                    [self copyItem:src to:[dstRoot stringByAppendingPathComponent:kid] error:nil];
                    copiedSub = YES;
                }
            }
            // AMG/NewDevice keychain dumps
            if (importKC) {
                for (NSString *kcName in @[@"keychain-full.plist", @"keychain-hints.plist", @"akc.plist"]) {
                    NSString *kcSrc = [srcRoot stringByAppendingPathComponent:kcName];
                    if (![fm fileExistsAtPath:kcSrc]) continue;
                    [fm createDirectoryAtPath:dstRoot withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *kcDst = [dstRoot stringByAppendingPathComponent:kcName];
                    [fm removeItemAtPath:kcDst error:nil];
                    [fm copyItemAtPath:kcSrc toPath:kcDst error:nil];
                }
                [self NDMaterializeKeychainFullFromAMGInAppDir:dstRoot importKeychain:YES];
            }
            continue;
        }

        // Non-bid dirs: apps/, UUID wrappers, phone folders — descend if they hold bids
        if ([entry.lowercaseString isEqualToString:@"apps"]) {
            [descend addObject:srcRoot];
            continue;
        }
        NSArray *kids = [fm contentsOfDirectoryAtPath:srcRoot error:nil] ?: @[];
        for (NSString *kid in kids) {
            if ([kid hasPrefix:@"."]) continue;
            if ([skip containsObject:kid]) continue;
            if ([kid rangeOfString:@"."].location == NSNotFound) continue;
            BOOL kidDir = NO;
            if ([fm fileExistsAtPath:[srcRoot stringByAppendingPathComponent:kid] isDirectory:&kidDir] && kidDir) {
                [descend addObject:srcRoot];
                break;
            }
        }
    }

    for (NSString *d in descend) {
        [self NDImportAMGHolographicFromDirectory:d intoRecord:recordName depth:depth + 1];
    }

    NSString *agSrc = [amgRecordDir stringByAppendingPathComponent:@"AppGroup"];
    if ([fm fileExistsAtPath:agSrc]) {
        NSString *agDst = [[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"AppGroup"];
        // Merge: keep existing AppGroup if already copied from a sibling
        if (![fm fileExistsAtPath:agDst]) {
            [fm copyItemAtPath:agSrc toPath:agDst error:nil];
        } else {
            // Prefer non-empty overwrite when destination is empty
            NSArray *dstKids = [fm contentsOfDirectoryAtPath:agDst error:nil] ?: @[];
            if (!dstKids.count) {
                [fm removeItemAtPath:agDst error:nil];
                [fm copyItemAtPath:agSrc toPath:agDst error:nil];
            }
        }
    }
}

- (BOOL)restoreAppGroupsForRecord:(NSString *)recordName {
    if (!recordName.length) return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *agLines = [NSMutableArray array];
    NSString *agRoot = [[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"AppGroup"];
    if (![fm fileExistsAtPath:agRoot]) {
        // Fall back to classic live AMG AppGroup
        NSString *livePath = [[[NSString stringWithContentsOfFile:[[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"amg-live-path.txt"]
                                                        encoding:NSUTF8StringEncoding error:nil]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
        if (!livePath.length) {
            NSString *liveName = [[NSString stringWithContentsOfFile:[[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"amg-live-name.txt"]
                                                           encoding:NSUTF8StringEncoding error:nil]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (liveName.length) livePath = [@"/var/mobile/AMG" stringByAppendingPathComponent:liveName];
        }
        if (livePath.length) {
            NSString *liveAG = [livePath stringByAppendingPathComponent:@"AppGroup"];
            if ([fm fileExistsAtPath:liveAG]) agRoot = liveAG;
        }
    }
    if (![fm fileExistsAtPath:agRoot]) {
        [agLines addObject:@"AppGroup: (no staged/live AppGroup tree)"];
        if (self.lastRestoreReport.length) {
            self.lastRestoreReport = [self.lastRestoreReport stringByAppendingFormat:@"\n%@", [agLines componentsJoinedByString:@"\n"]];
            [self writeRestoreReport:self.lastRestoreReport];
        }
        return YES;
    }

    NSUInteger agOK = 0, agSkip = 0;
    NSArray *appBids = [fm contentsOfDirectoryAtPath:agRoot error:nil] ?: @[];
    for (NSString *bid in appBids) {
        NSString *bidRoot = [agRoot stringByAppendingPathComponent:bid];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:bidRoot isDirectory:&isDir] || !isDir) continue;
        NSArray *containers = [fm contentsOfDirectoryAtPath:bidRoot error:nil] ?: @[];
        for (NSString *uuid in containers) {
            NSString *leaf = [bidRoot stringByAppendingPathComponent:uuid];
            if (![fm fileExistsAtPath:leaf isDirectory:&isDir] || !isDir) continue;

            NSString *groupId = nil;
            NSDictionary *hint = [NSDictionary dictionaryWithContentsOfFile:[leaf stringByAppendingPathComponent:@"nd-group-id.plist"]];
            if ([hint[@"groupId"] isKindOfClass:[NSString class]]) groupId = hint[@"groupId"];
            if (!groupId.length) {
                // Infer from Preferences/group.*.plist filenames (AMG layout)
                NSString *prefs = [leaf stringByAppendingPathComponent:@"Library/Preferences"];
                NSArray *prefFiles = [fm contentsOfDirectoryAtPath:prefs error:nil] ?: @[];
                for (NSString *f in prefFiles) {
                    if ([f hasPrefix:@"group."] && [f.pathExtension.lowercaseString isEqualToString:@"plist"]) {
                        groupId = [f stringByDeletingPathExtension];
                        break;
                    }
                }
            }
            if (!groupId.length) {
                // Metadata from AMG backup
                NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[leaf stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
                if ([meta[@"MCMMetadataIdentifier"] isKindOfClass:[NSString class]]) {
                    groupId = meta[@"MCMMetadataIdentifier"];
                }
            }
            if (!groupId.length) {
                agSkip++;
                [agLines addObject:[NSString stringWithFormat:@"AppGroup SKIP %@/%@ (no groupId)", bid, uuid]];
                continue;
            }

            NSString *live = [self sharedAppGroupPathForGroupId:groupId];
            if (!live.length) {
                agSkip++;
                [agLines addObject:[NSString stringWithFormat:@"AppGroup FAIL %@ — live container not found", groupId]];
                continue;
            }
            // Wipe live group trees first so previous env files cannot linger.
            for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
                NSString *lp = [live stringByAppendingPathComponent:sub];
                if ([fm fileExistsAtPath:lp]) {
                    [fm removeItemAtPath:lp error:nil];
                    [fm createDirectoryAtPath:lp withIntermediateDirectories:YES attributes:nil error:nil];
                }
            }
            for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
                NSString *src = [leaf stringByAppendingPathComponent:sub];
                if (![fm fileExistsAtPath:src]) continue;
                [self copyItem:src to:[live stringByAppendingPathComponent:sub] error:nil];
            }
            // AMG often parks sqlite / misc files at AppGroup container root
            NSArray *kids = [fm contentsOfDirectoryAtPath:leaf error:nil] ?: @[];
            for (NSString *kid in kids) {
                if ([kid hasPrefix:@"."]) continue;
                if ([kid isEqualToString:@"Documents"] || [kid isEqualToString:@"Library"] || [kid isEqualToString:@"tmp"]) continue;
                if ([kid isEqualToString:@"nd-group-id.plist"]) continue;
                NSString *src = [leaf stringByAppendingPathComponent:kid];
                BOOL kidDir = NO;
                [fm fileExistsAtPath:src isDirectory:&kidDir];
                if (kidDir) continue; // only lift root files; nested trees handled above
                [self copyItem:src to:[live stringByAppendingPathComponent:kid] error:nil];
            }
            [self relaxProtectionAtPath:live];
            agOK++;
            [agLines addObject:[NSString stringWithFormat:@"AppGroup OK %@ → %@", groupId, live]];
        }
    }
    [agLines addObject:[NSString stringWithFormat:@"AppGroup done ok=%lu skip=%lu", (unsigned long)agOK, (unsigned long)agSkip]];
    if (self.lastRestoreReport.length) {
        self.lastRestoreReport = [self.lastRestoreReport stringByAppendingFormat:@"\n%@", [agLines componentsJoinedByString:@"\n"]];
        [self writeRestoreReport:self.lastRestoreReport];
    }
    return YES;
}

/// Live sandbox probe for Filza-less debugging (Documents markers + sizes).
- (NSString *)probeLiveContainerForBundleId:(NSString *)bundleId {
    NSMutableArray *lines = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *container = [self containerPathForBundleId:bundleId];
    [lines addObject:[NSString stringWithFormat:@"bundle=%@", bundleId ?: @""]];
    [lines addObject:[NSString stringWithFormat:@"container=%@", container.length ? container : @"(not found)"]];
    if (!container.length) return [lines componentsJoinedByString:@"\n"];

    NSString *docs = [container stringByAppendingPathComponent:@"Documents"];
    NSString *lib = [container stringByAppendingPathComponent:@"Library"];
    [lines addObject:[NSString stringWithFormat:@"DocsKB=%llu LibKB=%llu",
                      [self byteSizeAtPath:docs] / 1024, [self byteSizeAtPath:lib] / 1024]];
    for (NSString *name in @[@"nd-restore-ok.txt", @"nd-akc-ok.txt", @"nd-identity-ok.txt", @"nd-tweak-loaded.txt", @"akc.plist", @"Model.sqlite"]) {
        NSString *p = [docs stringByAppendingPathComponent:name];
        BOOL ex = [fm fileExistsAtPath:p];
        [lines addObject:[NSString stringWithFormat:@"Documents/%@ exists=%@ size=%llu",
                          name, ex ? @"YES" : @"NO", [self byteSizeAtPath:p]]];
        if (ex && [name hasSuffix:@".txt"]) {
            NSString *t = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] ?: @"";
            if (t.length > 800) t = [[t substringToIndex:800] stringByAppendingString:@"…"];
            [lines addObject:[NSString stringWithFormat:@"--- %@ ---\n%@", name, t]];
        }
    }
    // Top Documents entries by size
    NSArray *kids = [fm contentsOfDirectoryAtPath:docs error:nil] ?: @[];
    NSMutableArray *sized = [NSMutableArray array];
    for (NSString *k in kids) {
        if ([k hasPrefix:@"."]) continue;
        unsigned long long sz = [self byteSizeAtPath:[docs stringByAppendingPathComponent:k]];
        [sized addObject:@{@"n": k, @"s": @(sz)}];
    }
    [sized sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"s"] compare:a[@"s"]];
    }];
    [lines addObject:@"Documents top:"];
    for (NSUInteger i = 0; i < MIN((NSUInteger)12, sized.count); i++) {
        NSDictionary *e = sized[i];
        [lines addObject:[NSString stringWithFormat:@"  %6lluKB  %@", [e[@"s"] unsignedLongLongValue] / 1024, e[@"n"]]];
    }
    NSString *prefs = [[lib stringByAppendingPathComponent:@"Preferences"]
                       stringByAppendingPathComponent:[bundleId stringByAppendingString:@".plist"]];
    [lines addObject:[NSString stringWithFormat:@"prefs exists=%@ size=%llu",
                      [fm fileExistsAtPath:prefs] ? @"YES" : @"NO", [self byteSizeAtPath:prefs]]];

    NSString *rtAkc = [[NDPaths runtimeStateDir] stringByAppendingPathComponent:@"last-akc-restore.txt"];
    NSString *rt = [NSString stringWithContentsOfFile:rtAkc encoding:NSUTF8StringEncoding error:nil];
    if (rt.length) [lines addObject:[NSString stringWithFormat:@"--- runtime last-akc-restore ---\n%@", rt]];
    else [lines addObject:@"runtime last-akc-restore: (missing) — tweak may not have run in Venmo"];

    NSString *tw = @"/var/jb/Library/NewDevice/last-tweak-loaded.txt";
    NSString *twBody = [NSString stringWithContentsOfFile:tw encoding:NSUTF8StringEncoding error:nil];
    if (!twBody.length) {
        twBody = [NSString stringWithContentsOfFile:@"/var/mobile/Media/NewDevice/last-tweak-loaded.txt" encoding:NSUTF8StringEncoding error:nil];
    }
    if (twBody.length) [lines addObject:[NSString stringWithFormat:@"--- last-tweak-loaded ---\n%@", twBody]];
    else [lines addObject:@"last-tweak-loaded: (missing) — NewDevice.dylib not injected into Venmo"];

    NSString *groupLive = [self sharedAppGroupPathForGroupId:@"group.net.kortina.labs.Venmo"];
    [lines addObject:[NSString stringWithFormat:@"AppGroup group.net.kortina.labs.Venmo=%@",
                      groupLive.length ? groupLive : @"(not found)"]];
    if (groupLive.length) {
        [lines addObject:[NSString stringWithFormat:@"  AppGroupKB=%llu", [self byteSizeAtPath:groupLive] / 1024]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (void)NDAppendPathProbe:(NSMutableArray *)lines path:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL ex = [fm fileExistsAtPath:path isDirectory:&isDir];
    if (!ex) {
        [lines addObject:[NSString stringWithFormat:@"MISS %@", path]];
        return;
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long sz = [attrs fileSize];
    NSDate *m = attrs[NSFileModificationDate];
    [lines addObject:[NSString stringWithFormat:@"OK %@ %@ size=%llu mtime=%@",
                      isDir ? @"dir" : @"file", path, sz, m ?: @""]];
}

- (NSString *)probeTweakInjection {
    NSMutableArray *lines = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    [lines addObject:@"=== NewDevice injection probe ==="];
    [lines addObject:[NSString stringWithFormat:@"time=%@", [NSDate date]]];

    NSArray *paths = @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NewDevice.dylib",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NewDevice.plist",
        @"/var/jb/usr/lib/TweakInject/NewDevice.dylib",
        @"/var/jb/usr/lib/TweakInject/NewDevice.plist",
        @"/var/jb/usr/lib/libellekit.dylib",
        @"/var/jb/usr/lib/libsubstrate.dylib",
        @"/var/jb/usr/lib/TweakLoader.dylib",
        @"/usr/lib/TweakLoader.dylib",
        @"/var/jb/Library/NewDevice/last-tweak-loaded.txt",
        @"/var/mobile/Media/NewDevice/last-tweak-loaded.txt",
        @"/var/jb/Applications/NewDevice.app/NewDevice",
        @"/var/jb/usr/local/bin/newdeviced",
    ];
    for (NSString *p in paths) [self NDAppendPathProbe:lines path:p];

    // List sibling tweaks (are ANY tweaks present?)
    for (NSString *dir in @[
             @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
             @"/var/jb/usr/lib/TweakInject",
         ]) {
        NSArray *kids = [fm contentsOfDirectoryAtPath:dir error:nil];
        if (!kids) {
            [lines addObject:[NSString stringWithFormat:@"list %@: (missing)", dir]];
            continue;
        }
        NSArray *dylibs = [[kids filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.dylib'"]]
                           sortedArrayUsingSelector:@selector(compare:)];
        [lines addObject:[NSString stringWithFormat:@"list %@: %lu dylibs", dir, (unsigned long)dylibs.count]];
        for (NSUInteger i = 0; i < MIN((NSUInteger)20, dylibs.count); i++) {
            [lines addObject:[NSString stringWithFormat:@"  - %@", dylibs[i]]];
        }
    }

    // Filter plist body
    NSString *filterPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NewDevice.plist";
    NSString *filterBody = [NSString stringWithContentsOfFile:filterPath encoding:NSUTF8StringEncoding error:nil];
    if (!filterBody.length) {
        id pl = [NSDictionary dictionaryWithContentsOfFile:filterPath];
        if (pl) filterBody = [pl description];
    }
    if (filterBody.length) {
        if (filterBody.length > 600) filterBody = [[filterBody substringToIndex:600] stringByAppendingString:@"…"];
        [lines addObject:[NSString stringWithFormat:@"--- NewDevice.plist ---\n%@", filterBody]];
    }

    NSString *marker = [NSString stringWithContentsOfFile:@"/var/jb/Library/NewDevice/last-tweak-loaded.txt"
                                                 encoding:NSUTF8StringEncoding error:nil];
    if (!marker.length) {
        marker = [NSString stringWithContentsOfFile:@"/var/mobile/Media/NewDevice/last-tweak-loaded.txt"
                                           encoding:NSUTF8StringEncoding error:nil];
    }
    if (marker.length) [lines addObject:[NSString stringWithFormat:@"--- last-tweak-loaded ---\n%@", marker]];
    else [lines addObject:@"last-tweak-loaded: (missing) — dylib never ran in any injected app since install/respring"];

    // Keychain readback for Venmo agrp (daemon can see what it wrote)
    NSString *bid = @"net.kortina.labs.Venmo";
    NSString *agrp = [self defaultKeychainAccessGroupForBundleId:bid] ?: @"";
    [lines addObject:[NSString stringWithFormat:@"venmoAgrp=%@", agrp.length ? agrp : @"(unknown)"]];
    if (agrp.length) {
        NSDictionary *q = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccessGroup: agrp,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
        };
        CFTypeRef result = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
        NSUInteger n = 0;
        if (st == errSecSuccess && result) {
            n = [(__bridge NSArray *)result count];
            CFRelease(result);
        } else if (result) {
            CFRelease(result);
        }
        [lines addObject:[NSString stringWithFormat:@"keychainReadback agrp items=%lu status=%d", (unsigned long)n, (int)st]];
    }

    [lines addObject:@"hint: if dylib OK but last-tweak-loaded missing → Dopamine/Choicy blocking injection or need Respring"];
    // Surface ElleKit safe-mode markers (blocks ALL app inject)
    for (NSString *p in @[
             @"/var/mobile/.eksafemode",
             @"/var/jb/var/mobile/.eksafemode",
             @"/var/mobile/Library/Preferences/.eksafemode",
         ]) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir]) {
            [lines addObject:[NSString stringWithFormat:@"SAFE MODE BLOCKER present: %@", p]];
        } else {
            [lines addObject:[NSString stringWithFormat:@"safemode MISS %@", p]];
        }
    }
    [lines addObject:@"hint: Venmo login needs in-app inject (identity + akc); daemon SecItemAdd alone is not enough"];
    NSString *body = [lines componentsJoinedByString:@"\n"];
    [body writeToFile:@"/var/mobile/Media/NewDevice/last-inject-probe.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return body;
}

- (id)generalPasteboard {
    Class PB = NSClassFromString(@"UIPasteboard");
    if (!PB || ![PB respondsToSelector:NSSelectorFromString(@"generalPasteboard")]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [PB performSelector:NSSelectorFromString(@"generalPasteboard")];
#pragma clang diagnostic pop
}

- (void)clearGeneralPasteboard {
    id board = [self generalPasteboard];
    if (board && [board respondsToSelector:NSSelectorFromString(@"setItems:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [board performSelector:NSSelectorFromString(@"setItems:") withObject:@[]];
#pragma clang diagnostic pop
    }
}

- (void)backupPasteboardToRecord:(NSString *)recordName {
    if (!recordName.length || [recordName isEqualToString:@"原始机器"]) return;
    id board = [self generalPasteboard];
    if (!board) return;
    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    if ([board respondsToSelector:NSSelectorFromString(@"string")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSString *s = [board performSelector:NSSelectorFromString(@"string")];
#pragma clang diagnostic pop
        if ([s isKindOfClass:[NSString class]] && s.length) snap[@"string"] = s;
    }
    if ([board respondsToSelector:NSSelectorFromString(@"items")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id items = [board performSelector:NSSelectorFromString(@"items")];
#pragma clang diagnostic pop
        // Only persist simple string-typed items to avoid huge binary blobs
        if ([items isKindOfClass:[NSArray class]]) {
            NSMutableArray *simple = [NSMutableArray array];
            for (id entry in (NSArray *)items) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *one = [NSMutableDictionary dictionary];
                [(NSDictionary *)entry enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                    if ([obj isKindOfClass:[NSString class]]) one[key] = obj;
                    else if ([obj isKindOfClass:[NSData class]] && [(NSData *)obj length] < 64 * 1024) {
                        one[key] = [(NSData *)obj base64EncodedStringWithOptions:0];
                        one[[NSString stringWithFormat:@"%@_b64", key]] = @YES;
                    }
                }];
                if (one.count) [simple addObject:one];
            }
            if (simple.count) snap[@"items"] = simple;
        }
    }
    if (!snap.count) {
        // Still write empty marker so restore clears
        snap[@"empty"] = @YES;
    }
    NSString *dir = [NDPaths pasteboardDirForRecord:recordName];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [snap writeToFile:[dir stringByAppendingPathComponent:@"general.plist"] atomically:YES];
}

- (void)restorePasteboardFromRecord:(NSString *)recordName {
    if (!recordName.length || [recordName isEqualToString:@"原始机器"]) {
        [self clearGeneralPasteboard];
        return;
    }
    NSString *path = [[NDPaths pasteboardDirForRecord:recordName] stringByAppendingPathComponent:@"general.plist"];
    NSDictionary *snap = [NSDictionary dictionaryWithContentsOfFile:path];
    id board = [self generalPasteboard];
    if (![snap isKindOfClass:[NSDictionary class]] || !board) {
        [self clearGeneralPasteboard];
        return;
    }
    if ([snap[@"empty"] boolValue]) {
        [self clearGeneralPasteboard];
        return;
    }
    NSString *s = snap[@"string"];
    if ([s isKindOfClass:[NSString class]] && s.length && [board respondsToSelector:NSSelectorFromString(@"setString:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [board performSelector:NSSelectorFromString(@"setString:") withObject:s];
#pragma clang diagnostic pop
        return;
    }
    NSArray *items = snap[@"items"];
    if ([items isKindOfClass:[NSArray class]] && items.count && [board respondsToSelector:NSSelectorFromString(@"setItems:")]) {
        NSMutableArray *restored = [NSMutableArray array];
        for (NSDictionary *entry in items) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *one = [NSMutableDictionary dictionary];
            [entry enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                if (![key isKindOfClass:[NSString class]]) return;
                if ([key hasSuffix:@"_b64"]) return;
                NSString *flag = [NSString stringWithFormat:@"%@_b64", key];
                if ([entry[flag] boolValue] && [obj isKindOfClass:[NSString class]]) {
                    NSData *data = [[NSData alloc] initWithBase64EncodedString:obj options:0];
                    if (data) one[key] = data;
                } else {
                    one[key] = obj;
                }
            }];
            if (one.count) [restored addObject:one];
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [board performSelector:NSSelectorFromString(@"setItems:") withObject:restored];
#pragma clang diagnostic pop
        return;
    }
    [self clearGeneralPasteboard];
}

- (NSUInteger)slimMediaInRecord:(NSString *)recordName {
    return [self slimMediaInDirectory:[NDPaths recordDir:recordName]];
}

- (NSUInteger)slimMediaInDirectory:(NSString *)root {
    if (!root.length) return 0;
    static NSSet *exts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exts = [NSSet setWithArray:@[
            @"jpg", @"jpeg", @"png", @"gif", @"heic", @"heif", @"webp", @"bmp", @"tiff", @"tif",
            @"mov", @"mp4", @"m4v", @"avi", @"mkv", @"3gp", @"webm"
        ]];
    });
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    NSUInteger removed = 0;
    NSString *rel = nil;
    while ((rel = [en nextObject])) {
        NSString *ext = rel.pathExtension.lowercaseString;
        if (![exts containsObject:ext]) continue;
        NSString *full = [root stringByAppendingPathComponent:rel];
        if ([fm removeItemAtPath:full error:nil]) removed++;
    }
    return removed;
}

@end
