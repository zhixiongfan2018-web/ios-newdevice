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

- (NSURL *)NDMCMContainerURLForClassNames:(NSArray<NSString *> *)classNames
                              identifier:(NSString *)identifier
                       createIfNecessary:(BOOL)create {
    if (!identifier.length) return nil;
    [[self class] loadMCM];
    for (NSString *clsName in classNames) {
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        id container = nil;
        // +containerWithIdentifier:createIfNecessary:existed:error:
        SEL selCreate = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
        if ([cls respondsToSelector:selCreate]) {
            BOOL existed = NO;
            NSError *err = nil;
            // objc_msgSend for BOOL/error out-params
            id (*msg)(Class, SEL, id, BOOL, BOOL *, NSError **) = (void *)objc_msgSend;
            container = msg(cls, selCreate, identifier, create, &existed, &err);
        }
        if (!container) {
            SEL sel = NSSelectorFromString(@"containerWithIdentifier:error:");
            if ([cls respondsToSelector:sel]) {
                NSError *err = nil;
                id (*msg)(Class, SEL, id, NSError **) = (void *)objc_msgSend;
                container = msg(cls, sel, identifier, &err);
            }
        }
        if (!container) continue;
        NSURL *url = nil;
        if ([container respondsToSelector:NSSelectorFromString(@"url")]) {
            url = ((NSURL *(*)(id, SEL))objc_msgSend)(container, NSSelectorFromString(@"url"));
        }
        if ([url isKindOfClass:[NSURL class]] && url.path.length) return url;
    }
    return nil;
}

- (NSString *)containerPathForBundleId:(NSString *)bundleId {
    if (!bundleId.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) MobileContainerManager — correct on iOS 12+ (LSApplicationProxy dataContainerURL is often wrong/nil)
    NSURL *mcm = [self NDMCMContainerURLForClassNames:@[
        @"MCMAppDataContainer",
        @"MCMDataContainer",
    ] identifier:bundleId createIfNecessary:YES];
    if (mcm.path.length && [fm fileExistsAtPath:mcm.path]) return mcm.path;

    // 2) Metadata scan (works when we can list containers as mobile/no-sandbox)
    for (NSString *appsRoot in @[
        @"/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/Application",
    ]) {
        NSArray *uuids = [fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
        for (NSString *uuid in uuids) {
            NSString *dir = [appsRoot stringByAppendingPathComponent:uuid];
            NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
            if ([plist[@"MCMMetadataIdentifier"] isEqualToString:bundleId]) return dir;
        }
    }

    // 3) Last resort: LSApplicationProxy (unreliable since iOS 12, kept as fallback)
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy && [LSApplicationProxy respondsToSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")]) {
        id (*msg)(Class, SEL, id) = (void *)objc_msgSend;
        id proxy = msg(LSApplicationProxy, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleId);
        if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")]) {
            NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"dataContainerURL"));
            if ([url isKindOfClass:[NSURL class]] && url.path.length && [fm fileExistsAtPath:url.path]) return url.path;
        }
    }
    return mcm.path.length ? mcm.path : nil; // return created path even if not yet visible
}

- (void)tryLaunchAppToCreateContainer:(NSString *)bundleId {
    if (!bundleId.length) return;
    Class WS = NSClassFromString(@"LSApplicationWorkspace");
    if (!WS || ![WS respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) return;
    id (*msg0)(Class, SEL) = (void *)objc_msgSend;
    id ws = msg0(WS, NSSelectorFromString(@"defaultWorkspace"));
    if (!ws) return;
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if ([ws respondsToSelector:openSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(ws, openSel, bundleId);
        [NSThread sleepForTimeInterval:1.2];
        [self terminateApps:@[bundleId]];
        [NSThread sleepForTimeInterval:0.4];
    }
}

- (BOOL)mirrorTree:(NSString *)src to:(NSString *)dst error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return YES;
    // Prefer rsync/ditto for large AMG trees (Venmo ~22MB)
    for (NSArray *cmd in @[
        @[@"/var/jb/usr/bin/rsync", @"-a", @"--delete", [src stringByAppendingString:@"/"], [dst stringByAppendingString:@"/"]],
        @[@"/usr/bin/rsync", @"-a", @"--delete", [src stringByAppendingString:@"/"], [dst stringByAppendingString:@"/"]],
        @[@"/var/jb/usr/bin/ditto", src, dst],
        @[@"/usr/bin/ditto", src, dst],
    ]) {
        NSString *bin = cmd[0];
        if (![fm isExecutableFileAtPath:bin]) continue;
        [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
        NSArray *args = [cmd subarrayWithRange:NSMakeRange(1, cmd.count - 1)];
        // For rsync, ensure trailing slash semantics; for ditto replace dst
        if ([bin.lastPathComponent isEqualToString:@"ditto"]) {
            [fm removeItemAtPath:dst error:nil];
        }
        [self runCommand:bin arguments:args];
        if ([fm fileExistsAtPath:dst]) return YES;
    }
    return [self copyItem:src to:dst error:error];
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

    NSString *container = [self containerPathForBundleId:bid];
    if (!container.length) {
        [self tryLaunchAppToCreateContainer:bid];
        container = [self containerPathForBundleId:bid];
    }
    if (!container.length) {
        [missing addObject:bid];
        [lines addObject:[NSString stringWithFormat:@"FAIL %@ — 未找到数据容器（请确认已安装该 App）", bid]];
        return NO;
    }

    NSUInteger okSubs = 0;
    for (NSString *sub in @[@"Documents", @"Library", @"tmp", @"SystemData"]) {
        NSString *src = [backupRoot stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:src]) continue;
        NSString *dst = [container stringByAppendingPathComponent:sub];
        NSError *e = nil;
        if ([self mirrorTree:src to:dst error:&e]) okSubs++;
        else [lines addObject:[NSString stringWithFormat:@"  copy fail %@/%@: %@", bid, sub, e.localizedDescription ?: @"?"]];
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
    [self restoreKeychainHintsForApps:@[bid] fromRecord:recordName];

    unsigned long long liveDocs = [self byteSizeAtPath:[container stringByAppendingPathComponent:@"Documents"]];
    unsigned long long liveLib = [self byteSizeAtPath:[container stringByAppendingPathComponent:@"Library"]];
    BOOL verified = (liveDocs + liveLib) >= (staged / 4); // rough: at least some payload landed
    [lines addObject:[NSString stringWithFormat:@"%@ %@ → %@\n  staged=%lluKB live Docs+Lib=%lluKB subs=%lu",
                      verified ? @"OK" : @"WARN",
                      bid, container, staged / 1024, (liveDocs + liveLib) / 1024, (unsigned long)okSubs]];
    return verified;
}

- (BOOL)restoreApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName error:(NSError **)error {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"restore record=%@ apps=%lu", recordName, (unsigned long)bundleIds.count]];
    NSUInteger ok = 0;
    for (NSString *bid in bundleIds) {
        if ([self restoreOneApp:bid fromRecord:recordName lines:lines missing:missing]) ok++;
    }
    [self restoreAppGroupsForRecord:recordName];
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
    for (NSString *b in [[NSArray arrayWithContentsOfFile:[[NDPaths recordDir:recordName] stringByAppendingPathComponent:@"selectApp.plist"]] ?: @[]) {
        if ([b isKindOfClass:[NSString class]] && b.length && ![bids containsObject:b]) {
            // only if staged exists
            if ([fm fileExistsAtPath:[NDPaths appsBackupDirForRecord:recordName bundleId:b]]) [bids addObject:b];
        }
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

- (BOOL)restoreKeychainHintsForApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName {
    for (NSString *bid in bundleIds) {
        NSString *dir = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
        NSString *fullPath = [dir stringByAppendingPathComponent:@"keychain-full.plist"];
        NSString *hintPath = [dir stringByAppendingPathComponent:@"keychain-hints.plist"];
        NSArray *items = [NSArray arrayWithContentsOfFile:fullPath];
        if (![items isKindOfClass:[NSArray class]]) items = [NSArray arrayWithContentsOfFile:hintPath];
        if (![items isKindOfClass:[NSArray class]]) continue;

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
                if (![service containsString:bid] && ![account containsString:bid] && ![accessGroup containsString:bid]) continue;
                NSMutableDictionary *del = [@{
                    (__bridge id)kSecClass: secClass,
                } mutableCopy];
                if (service.length) del[(__bridge id)kSecAttrService] = service;
                if (account.length) del[(__bridge id)kSecAttrAccount] = account;
                if (accessGroup.length) del[(__bridge id)kSecAttrAccessGroup] = accessGroup;
                SecItemDelete((__bridge CFDictionaryRef)del);
            }
        }

        for (NSDictionary *item in items) {
            NSString *cls = item[@"class"] ?: @"generic";
            NSData *data = [[NSData alloc] initWithBase64EncodedString:item[@"data"] ?: @"" options:0];
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
                    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
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
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
            OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
            if (st == errSecMissingEntitlement && accessGroup.length) {
                // Retry without access group when entitlement mismatch
                [add removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
                SecItemAdd((__bridge CFDictionaryRef)add, NULL);
            }
        }
    }
    return YES;
}

- (NSString *)sharedAppGroupPathForGroupId:(NSString *)groupId {
    if (!groupId.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *mcm = [self NDMCMContainerURLForClassNames:@[
        @"MCMSharedAppGroupContainer",
        @"MCMAppGroupContainer",
        @"MCMSharedDataContainer",
    ] identifier:groupId createIfNecessary:YES];
    if (mcm.path.length && [fm fileExistsAtPath:mcm.path]) return mcm.path;

    for (NSString *root in @[
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Shared/AppGroup",
    ]) {
        NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
        for (NSString *uuid in uuids) {
            NSString *dir = [root stringByAppendingPathComponent:uuid];
            NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
            if ([plist[@"MCMMetadataIdentifier"] isEqualToString:groupId]) return dir;
        }
    }
    return mcm.path;
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
        // AMG/NewDevice may keep keychain dumps at <bid>/keychain-*.plist (not under Library/)
        if (importKC) {
            for (NSString *kcName in @[@"keychain-full.plist", @"keychain-hints.plist"]) {
                NSString *kcSrc = [srcRoot stringByAppendingPathComponent:kcName];
                if (![fm fileExistsAtPath:kcSrc]) continue;
                [fm createDirectoryAtPath:dstRoot withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *kcDst = [dstRoot stringByAppendingPathComponent:kcName];
                [fm removeItemAtPath:kcDst error:nil];
                [fm copyItemAtPath:kcSrc toPath:kcDst error:nil];
            }
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
