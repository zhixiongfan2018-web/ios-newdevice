#import "NDAppDataManager.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

@interface NDAppDataManager ()
@property (nonatomic, copy, readwrite) NSString *lastRestoreReport;
- (NSArray *)NDKeychainItemsFromAMGAkcDictionary:(NSDictionary *)akc;
- (NSArray *)NDLoadKeychainItemsFromBackupDir:(NSString *)dir;
- (BOOL)NDBackupDirHasKeychainDump:(NSString *)dir;
- (void)NDMaterializeKeychainFullFromAMGInAppDir:(NSString *)dstRoot importKeychain:(BOOL)importKC;
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
            if ([plist[@"MCMMetadataIdentifier"] isEqualToString:identifier]) return dir;
        }
    }
    return nil;
}

- (NSURL *)NDMCMContainerURLSafe:(NSString *)identifier classNames:(NSArray<NSString *> *)classNames {
    // Never use createIfNecessary — wrong objc_msgSend ABI / missing entitlement can crash
    // the whole app/daemon and break 一键新机. Pass NULL for NSError** to keep ABI simple.
    if (!identifier.length) return nil;
    [[self class] loadMCM];
    for (NSString *clsName in classNames) {
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        @try {
            SEL sel = NSSelectorFromString(@"containerWithIdentifier:error:");
            if (![cls respondsToSelector:sel]) continue;
            id (*msg)(Class, SEL, id, void *) = (void *)objc_msgSend;
            id container = msg(cls, sel, identifier, NULL);
            if (!container) continue;
            if ([container respondsToSelector:NSSelectorFromString(@"url")]) {
                NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(container, NSSelectorFromString(@"url"));
                if ([url isKindOfClass:[NSURL class]] && url.path.length) return url;
            }
        } @catch (__unused NSException *ex) {
            NSLog(@"[NewDevice] MCM lookup exception for %@", identifier);
        }
    }
    return nil;
}

- (NSString *)containerPathForBundleId:(NSString *)bundleId {
    if (!bundleId.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) Metadata scan FIRST — safe, no private API ABI risk (fixes 一键新机 crash)
    NSString *scanned = [self NDScanContainerUnderRoots:@[
        @"/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/Application",
    ] identifier:bundleId];
    if (scanned.length) return scanned;

    // 2) Safe MCM lookup (no createIfNecessary)
    NSURL *mcm = [self NDMCMContainerURLSafe:bundleId classNames:@[@"MCMAppDataContainer", @"MCMDataContainer"]];
    if (mcm.path.length && [fm fileExistsAtPath:mcm.path]) return mcm.path;

    // 3) LSApplicationProxy last resort
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
    }
    return YES;
}

- (BOOL)backupApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName error:(NSError **)error {
    for (NSString *bid in bundleIds) {
        NSString *container = [self containerPathForBundleId:bid];
        if (!container) continue;
        NSString *backupRoot = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
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

- (BOOL)restoreOneApp:(NSString *)bid
           fromRecord:(NSString *)recordName
                lines:(NSMutableArray<NSString *> *)lines
              missing:(NSMutableArray<NSString *> *)missing {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *backupRoot = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
    if (![fm fileExistsAtPath:backupRoot]) return NO;
    unsigned long long staged = [self byteSizeAtPath:backupRoot];
    if (staged == 0) {
        [lines addObject:[NSString stringWithFormat:@"SKIP %@ (staged empty)", bid]];
        return NO;
    }

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

    // Ensure live Documents has akc.plist for in-app tweak restore (access-group safe)
    NSString *liveDocsPath = [container stringByAppendingPathComponent:@"Documents"];
    if (hasKC) {
        NSString *liveAkc = [liveDocsPath stringByAppendingPathComponent:@"akc.plist"];
        if (![fm fileExistsAtPath:liveAkc]) {
            for (NSString *rel in @[@"akc.plist", @"Documents/akc.plist"]) {
                NSString *src = [backupRoot stringByAppendingPathComponent:rel];
                if (![fm fileExistsAtPath:src]) continue;
                [fm createDirectoryAtPath:liveDocsPath withIntermediateDirectories:YES attributes:nil error:nil];
                [fm removeItemAtPath:liveAkc error:nil];
                if ([fm copyItemAtPath:src toPath:liveAkc error:nil]) {
                    [self relaxProtectionAtPath:liveAkc];
                    break;
                }
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
                      hasKC ? @"已暂存 akc；NewDevice 进程尝试写入 + 打开 App 时插件在进程内再写（看 Documents/nd-akc-ok.txt）"
                            : @"此包无 Keychain/akc。沙盒文件可写入，但 Venmo 会显示未登录（看起来像空的）"]];
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
    [self restoreAppGroupsForRecord:recordName];
    NSString *importNote = [[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"amg-import-note.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:importNote]) {
        NSString *note = [NSString stringWithContentsOfFile:importNote encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [lines addObject:[NSString stringWithFormat:@"WARN identity: %@", note.length ? note : @"faker ciphertext → randomized identity"]];
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
    if (!recordName.length || [recordName isEqualToString:@"原始机器"]) return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appsRoot = [[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"apps"];
    NSArray *entries = [fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
    NSMutableArray<NSString *> *bids = [NSMutableArray array];
    for (NSString *e in entries) {
        if ([e hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[appsRoot stringByAppendingPathComponent:e] isDirectory:&isDir] && isDir) {
            [bids addObject:e];
        }
    }
    // Also include selectApp ids so we attempt launch-to-create for installed-but-empty
    NSArray *selectApps = [NSArray arrayWithContentsOfFile:[[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"selectApp.plist"]];
    if (![selectApps isKindOfClass:[NSArray class]]) selectApps = @[];
    for (id item in selectApps) {
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *b = (NSString *)item;
        if (!b.length || [bids containsObject:b]) continue;
        if ([fm fileExistsAtPath:[NDPaths appsBackupDirForRecord:recordName bundleId:b]]) [bids addObject:b];
    }
    return [self restoreApps:bids fromRecord:recordName error:error];
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
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *bid in bundleIds) {
        NSString *dir = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
        // Materialize AMG akc → keychain-full if needed (imports that only staged Documents/)
        [self NDMaterializeKeychainFullFromAMGInAppDir:dir importKeychain:YES];
        NSArray *items = [self NDLoadKeychainItemsFromBackupDir:dir];
        if (![items isKindOfClass:[NSArray class]] || !items.count) {
            [parts addObject:[NSString stringWithFormat:@"%@: items=0", bid]];
            continue;
        }

        // Collect services/accounts from dump so VenmoKit / token entries get cleared even when
        // their service string does not contain the bundle id.
        NSMutableSet *dumpServices = [NSMutableSet set];
        NSMutableSet *dumpAccounts = [NSMutableSet set];
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            if ([it[@"service"] isKindOfClass:[NSString class]] && [it[@"service"] length]) [dumpServices addObject:it[@"service"]];
            if ([it[@"account"] isKindOfClass:[NSString class]] && [it[@"account"] length]) [dumpAccounts addObject:it[@"account"]];
        }

        // Clear existing items that look related before restore (avoid duplicates)
        for (id secClass in @[ (__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword ]) {
            NSDictionary *query = @{
                (__bridge id)kSecClass: secClass,
                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                (__bridge id)kSecReturnAttributes: @YES,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
            };
            CFTypeRef result = NULL;
            if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) {
                if (result) CFRelease(result);
                continue;
            }
            NSArray *arr = (__bridge_transfer NSArray *)result;
            for (NSDictionary *item in arr) {
                NSString *service = item[(__bridge id)kSecAttrService] ?: @"";
                NSString *account = item[(__bridge id)kSecAttrAccount] ?: @"";
                NSString *accessGroup = item[(__bridge id)kSecAttrAccessGroup] ?: @"";
                BOOL related = [service containsString:bid] || [account containsString:bid] || [accessGroup containsString:bid]
                    || (service.length && [dumpServices containsObject:service])
                    || (account.length && [dumpAccounts containsObject:account]);
                if (!related) continue;
                NSMutableDictionary *del = [@{
                    (__bridge id)kSecClass: secClass,
                } mutableCopy];
                if (service.length) del[(__bridge id)kSecAttrService] = service;
                if (account.length) del[(__bridge id)kSecAttrAccount] = account;
                if (accessGroup.length) del[(__bridge id)kSecAttrAccessGroup] = accessGroup;
                SecItemDelete((__bridge CFDictionaryRef)del);
            }
        }

        NSUInteger added = 0;
        NSUInteger failed = 0;
        NSMutableArray *failCodes = [NSMutableArray array];
        for (NSDictionary *item in items) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *cls = item[@"class"] ?: @"generic";
            NSData *data = nil;
            id rawData = item[@"data"];
            if ([rawData isKindOfClass:[NSData class]]) {
                data = rawData;
            } else if ([rawData isKindOfClass:[NSString class]]) {
                data = [[NSData alloc] initWithBase64EncodedString:rawData options:0];
            }
            if ([cls isEqualToString:@"certificate"]) {
                if (!data.length) continue;
                NSMutableDictionary *add = [@{
                    (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
                    (__bridge id)kSecValueData: data,
                } mutableCopy];
                if (item[@"label"]) add[(__bridge id)kSecAttrLabel] = item[@"label"];
                if (item[@"accessGroup"]) add[(__bridge id)kSecAttrAccessGroup] = item[@"accessGroup"];
                OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
                if (st == errSecMissingEntitlement && item[@"accessGroup"]) {
                    [add removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
                    st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
                }
                if (st == errSecSuccess || st == errSecDuplicateItem) added++;
                else {
                    failed++;
                    if (failCodes.count < 6) [failCodes addObject:[NSString stringWithFormat:@"%d", (int)st]];
                }
                continue;
            }
            if (!data.length) continue;
            CFStringRef secClass = [cls isEqualToString:@"internet"] ? kSecClassInternetPassword : kSecClassGenericPassword;
            NSMutableDictionary *del = [@{
                (__bridge id)kSecClass: (__bridge id)secClass,
            } mutableCopy];
            NSString *service = item[@"service"] ?: @"";
            NSString *account = item[@"account"] ?: @"";
            NSString *accessGroup = item[@"accessGroup"] ?: @"";
            NSString *server = item[@"server"] ?: @"";
            if (!service.length && !server.length && !account.length) continue;
            if (service.length) del[(__bridge id)kSecAttrService] = service;
            if (account.length) del[(__bridge id)kSecAttrAccount] = account;
            if (server.length) del[(__bridge id)kSecAttrServer] = server;
            if (accessGroup.length) del[(__bridge id)kSecAttrAccessGroup] = accessGroup;
            SecItemDelete((__bridge CFDictionaryRef)del);

            NSMutableDictionary *add = [del mutableCopy];
            add[(__bridge id)kSecValueData] = data;
            if (item[@"label"]) add[(__bridge id)kSecAttrLabel] = item[@"label"];
            if (item[@"path"]) add[(__bridge id)kSecAttrPath] = item[@"path"];
            if (item[@"port"]) add[(__bridge id)kSecAttrPort] = item[@"port"];
            if (item[@"synchronizable"]) add[(__bridge id)kSecAttrSynchronizable] = item[@"synchronizable"];
            // Prefer AfterFirstUnlock so background restore works
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
            OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
            BOOL strippedAgrp = NO;
            if (st == errSecMissingEntitlement && accessGroup.length) {
                // Retry without access group when entitlement mismatch (may be invisible to Venmo)
                [add removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
                st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
                strippedAgrp = YES;
            }
            if (st == errSecDuplicateItem) {
                NSMutableDictionary *query = [del mutableCopy];
                NSDictionary *attrs = @{ (__bridge id)kSecValueData: data };
                st = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs);
            }
            if (st == errSecSuccess) {
                added++;
                if (strippedAgrp && failCodes.count < 6) [failCodes addObject:@"strippedAgrp"];
            } else {
                failed++;
                if (failCodes.count < 6) [failCodes addObject:[NSString stringWithFormat:@"%d", (int)st]];
            }
        }
        NSString *line = [NSString stringWithFormat:@"%@: items=%lu added=%lu failed=%lu%@",
                          bid, (unsigned long)items.count, (unsigned long)added, (unsigned long)failed,
                          failCodes.count ? [NSString stringWithFormat:@" codes=%@", [failCodes componentsJoinedByString:@","]] : @""];
        [parts addObject:line];
        NSLog(@"[NewDevice] keychain restore %@", line);
    }
    return parts.count ? [parts componentsJoinedByString:@"; "] : @"none";
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
    if (!amgRecordDir.length || !recordName.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:amgRecordDir error:nil] ?: @[];
    static NSSet *skip;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skip = [NSSet setWithArray:@[@"AppGroup", @"Pasteboard", @"Documents", @"Library", @"tmp", @"SystemData"]];
    });

    BOOL importKC = [NDConfig shared].importKeychainWithData;

    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        if ([skip containsObject:entry]) continue;
        if ([entry.pathExtension.lowercaseString isEqualToString:@"plist"]) continue;
        if ([entry.pathExtension.lowercaseString isEqualToString:@"txt"]) continue;
        // Bundle-id folders look like com.foo.bar
        if ([entry rangeOfString:@"."].location == NSNotFound) continue;
        NSString *srcRoot = [amgRecordDir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:srcRoot isDirectory:&isDir] || !isDir) continue;
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
        // AMG/NewDevice keychain dumps:
        // - NewDevice: <bid>/keychain-full.plist
        // - AMG: <bid>/akc.plist or <bid>/Documents/akc.plist (copied with Documents/)
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
    }

    NSString *agSrc = [amgRecordDir stringByAppendingPathComponent:@"AppGroup"];
    if ([fm fileExistsAtPath:agSrc]) {
        NSString *agDst = [[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"AppGroup"];
        [fm removeItemAtPath:agDst error:nil];
        [fm copyItemAtPath:agSrc toPath:agDst error:nil];
    }
}

- (BOOL)restoreAppGroupsForRecord:(NSString *)recordName {
    if (!recordName.length) return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *agRoot = [[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"AppGroup"];
    if (![fm fileExistsAtPath:agRoot]) return YES;

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
            if (!groupId.length) continue;

            NSString *live = [self sharedAppGroupPathForGroupId:groupId];
            if (!live.length) continue;
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
        }
    }
    return YES;
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
