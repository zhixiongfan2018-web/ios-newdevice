#import "NDAppDataManager.h"
#import "NDPaths.h"
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

@implementation NDAppDataManager

+ (instancetype)shared {
    static NDAppDataManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        m = [NDAppDataManager new];
    });
    return m;
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
        [self runCommand:@"/var/jb/usr/bin/killall" arguments:@[@"-9", bid.lastPathComponent]];
        [self runCommand:@"/usr/bin/killall" arguments:@[@"-9", bid.lastPathComponent]];
    }
}

#pragma mark - Containers

- (NSString *)containerPathForBundleId:(NSString *)bundleId {
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy && [LSApplicationProxy respondsToSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id proxy = [LSApplicationProxy performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:bundleId];
#pragma clang diagnostic pop
        if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            NSURL *url = [proxy performSelector:NSSelectorFromString(@"dataContainerURL")];
#pragma clang diagnostic pop
            if ([url isKindOfClass:[NSURL class]]) return url.path;
        }
    }

    NSString *appsRoot = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsRoot error:nil];
    for (NSString *uuid in uuids) {
        NSString *meta = [[appsRoot stringByAppendingPathComponent:uuid] stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([plist[@"MCMMetadataIdentifier"] isEqualToString:bundleId]) {
            return [appsRoot stringByAppendingPathComponent:uuid];
        }
    }
    return nil;
}

- (NSString *)sharedContainerPathForGroupId:(NSString *)groupId {
    if (!groupId.length) return nil;

    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    // Some firmwares expose groupContainerURLs on the owning app proxy; try common group ids via scan below.
    (void)LSApplicationProxy;

    NSString *root = @"/var/mobile/Containers/Shared/AppGroup";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString *uuid in uuids) {
        NSString *dir = [root stringByAppendingPathComponent:uuid];
        NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([plist[@"MCMMetadataIdentifier"] isEqualToString:groupId]) {
            return dir;
        }
    }
    return nil;
}

- (NSArray<NSString *> *)candidateGroupIdsForBundleId:(NSString *)bundleId backupAppGroupRoot:(NSString *)agBackup {
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    if (bundleId.length) {
        [ids addObject:[@"group." stringByAppendingString:bundleId]];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (agBackup.length) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:agBackup];
        for (NSString *rel in en) {
            NSString *base = rel.lastPathComponent;
            if ([base hasPrefix:@"group."] && [base.pathExtension.lowercaseString isEqualToString:@"plist"]) {
                [ids addObject:base.stringByDeletingPathExtension];
            }
            if ([base isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"]) {
                NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[agBackup stringByAppendingPathComponent:rel]];
                NSString *mid = meta[@"MCMMetadataIdentifier"];
                if ([mid isKindOfClass:[NSString class]] && [mid hasPrefix:@"group."]) {
                    [ids addObject:mid];
                }
            }
        }
    }
    return ids.array;
}

#pragma mark - Copy helpers

- (BOOL)copyItem:(NSString *)src to:(NSString *)dst error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dst]) {
        if (![fm removeItemAtPath:dst error:error]) return NO;
    }
    NSString *parent = [dst stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parent]) {
        if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    }
    if (![fm fileExistsAtPath:src]) return YES;
    return [fm copyItemAtPath:src toPath:dst error:error];
}

- (BOOL)copyDirectoryContents:(NSString *)src into:(NSString *)dst error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return YES;
    if (![fm fileExistsAtPath:dst]) {
        if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    }
    NSArray *kids = [fm contentsOfDirectoryAtPath:src error:nil] ?: @[];
    for (NSString *name in kids) {
        if ([name isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"]) continue;
        NSString *s = [src stringByAppendingPathComponent:name];
        NSString *d = [dst stringByAppendingPathComponent:name];
        [self copyItem:s to:d error:nil];
    }
    return YES;
}

- (NSString *)payloadDirInsideAppGroupBackup:(NSString *)agBackup {
    // AMG layout: AppGroup/<bid>/<UUID>/{Library,...}
    // ND layout may already be AppGroup/{Library,...} or AppGroup/<UUID>/...
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:agBackup isDirectory:&isDir] || !isDir) return nil;

    NSArray *kids = [fm contentsOfDirectoryAtPath:agBackup error:nil] ?: @[];
    BOOL looksLikeContainer = NO;
    for (NSString *k in kids) {
        if ([k isEqualToString:@"Library"] || [k isEqualToString:@"Documents"] || [k isEqualToString:@"tmp"]
            || [k hasPrefix:@"."] || [k hasSuffix:@".sqlite"] || [k hasSuffix:@".sqlite-wal"]) {
            looksLikeContainer = YES;
            break;
        }
    }
    if (looksLikeContainer) return agBackup;

    for (NSString *k in kids) {
        NSString *p = [agBackup stringByAppendingPathComponent:k];
        BOOL d = NO;
        if (![fm fileExistsAtPath:p isDirectory:&d] || !d) continue;
        // UUID-ish or nested payload
        NSArray *inner = [fm contentsOfDirectoryAtPath:p error:nil] ?: @[];
        for (NSString *n in inner) {
            if ([n isEqualToString:@"Library"] || [n isEqualToString:@"Documents"]
                || [n isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"]) {
                return p;
            }
        }
    }
    return agBackup;
}

#pragma mark - AMG live fallback

+ (NSString *)normalizedRecordToken:(NSString *)name {
    if (!name.length) return @"";
    NSMutableString *s = [NSMutableString stringWithString:name];
    [s replaceOccurrencesOfString:@"+" withString:@"" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@" " withString:@"-" options:0 range:NSMakeRange(0, s.length)];
    while ([s containsString:@"--"]) {
        [s replaceOccurrencesOfString:@"--" withString:@"-" options:0 range:NSMakeRange(0, s.length)];
    }
    return s;
}

- (NSString *)amgLiveAppRootForBundleId:(NSString *)bundleId recordName:(NSString *)recordName {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *amgRoot = @"/var/mobile/AMG";
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:amgRoot isDirectory:&isDir] || !isDir) return nil;

    NSString *want = [[self class] normalizedRecordToken:recordName];
    NSArray *recs = [fm contentsOfDirectoryAtPath:amgRoot error:nil] ?: @[];
    for (NSString *rec in recs) {
        NSString *got = [[self class] normalizedRecordToken:rec];
        if (![got isEqualToString:want] && ![got containsString:want] && ![want containsString:got]) continue;
        NSString *appDir = [[amgRoot stringByAppendingPathComponent:rec] stringByAppendingPathComponent:bundleId];
        if ([fm fileExistsAtPath:appDir isDirectory:&isDir] && isDir) return appDir;
    }
    return nil;
}

- (NSString *)resolveBackupRootForBundleId:(NSString *)bundleId recordName:(NSString *)recordName {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *nd = [NDPaths appsBackupDirForRecord:recordName bundleId:bundleId];
    if ([fm fileExistsAtPath:nd]) {
        // Prefer ND if it has any payload
        for (NSString *sub in @[@"Documents", @"Library", @"tmp", @"AppGroup", @"akc.plist"]) {
            if ([fm fileExistsAtPath:[nd stringByAppendingPathComponent:sub]]) return nd;
        }
    }
    NSString *amgApp = [self amgLiveAppRootForBundleId:bundleId recordName:recordName];
    if (amgApp.length) return amgApp;
    return nd;
}

#pragma mark - Clear / backup / restore

- (BOOL)clearDataForApps:(NSArray<NSString *> *)bundleIds error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *bid in bundleIds) {
        NSString *container = [self containerPathForBundleId:bid];
        if (!container) continue;
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            NSString *path = [container stringByAppendingPathComponent:sub];
            if ([fm fileExistsAtPath:path]) {
                [fm removeItemAtPath:path error:nil];
                [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
            }
        }
    }
    return YES;
}

- (BOOL)backupAppGroupsForBundleId:(NSString *)bid toBackupRoot:(NSString *)backupRoot {
    NSArray *groupIds = [self candidateGroupIdsForBundleId:bid backupAppGroupRoot:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dstRoot = [backupRoot stringByAppendingPathComponent:@"AppGroup"];
    BOOL any = NO;
    for (NSString *gid in groupIds) {
        NSString *live = [self sharedContainerPathForGroupId:gid];
        if (!live.length) continue;
        // Store as AppGroup/<UUID-or-flat> matching AMG: nest under a single payload dir
        NSString *dst = [dstRoot stringByAppendingPathComponent:live.lastPathComponent];
        [self copyDirectoryContents:live into:dst error:nil];
        // ensure metadata identifier preserved for restore hints
        NSString *metaSrc = [live stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        if ([fm fileExistsAtPath:metaSrc]) {
            [self copyItem:metaSrc to:[dst stringByAppendingPathComponent:metaSrc.lastPathComponent] error:nil];
        }
        any = YES;
    }
    return any;
}

- (BOOL)restoreAppGroupsForBundleId:(NSString *)bid fromBackupRoot:(NSString *)backupRoot {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *agBackup = [backupRoot stringByAppendingPathComponent:@"AppGroup"];
    // Classic AMG live app root has sibling AppGroup under record, not under bid —
    // NDAMGImporter already nests under bid/AppGroup. Also support record-level via parent.
    if (![fm fileExistsAtPath:agBackup]) {
        // If backupRoot is AMG live app dir (.../AMG/<rec>/<bid>), AppGroup is ../AppGroup/<bid>
        NSString *parent = [[backupRoot stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"AppGroup"];
        NSString *alt = [parent stringByAppendingPathComponent:bid];
        if ([fm fileExistsAtPath:alt]) agBackup = alt;
        else return YES;
    }

    NSString *payload = [self payloadDirInsideAppGroupBackup:agBackup];
    if (!payload.length) return YES;

    NSArray *groupIds = [self candidateGroupIdsForBundleId:bid backupAppGroupRoot:agBackup];
    for (NSString *gid in groupIds) {
        NSString *live = [self sharedContainerPathForGroupId:gid];
        if (!live.length) continue;
        [self copyDirectoryContents:payload into:live error:nil];
        return YES;
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
            [self copyItem:src to:dst error:error];
        }
        [self backupAppGroupsForBundleId:bid toBackupRoot:backupRoot];
        [self backupAKCForBundleId:bid container:container toBackupRoot:backupRoot];
        [self backupKeychainHintsForApps:@[bid] toRecord:recordName];
    }
    return YES;
}

- (BOOL)restoreApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *bid in bundleIds) {
        NSString *container = [self containerPathForBundleId:bid];
        if (!container) continue;
        NSString *backupRoot = [self resolveBackupRootForBundleId:bid recordName:recordName];
        BOOL hasBackup = NO;
        for (NSString *sub in @[@"Documents", @"Library", @"tmp", @"AppGroup"]) {
            if ([fm fileExistsAtPath:[backupRoot stringByAppendingPathComponent:sub]]) {
                hasBackup = YES;
                break;
            }
        }
        if (!hasBackup) {
            [self clearDataForApps:@[bid] error:nil];
            continue;
        }
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            NSString *src = [backupRoot stringByAppendingPathComponent:sub];
            NSString *dst = [container stringByAppendingPathComponent:sub];
            [self copyItem:src to:dst error:nil];
        }
        [self restoreAppGroupsForBundleId:bid fromBackupRoot:backupRoot];

        // Prefer AMG akc.plist (Documents or backup root) over weak hints.
        NSArray *akcCandidates = @[
            [backupRoot stringByAppendingPathComponent:@"Documents/akc.plist"],
            [container stringByAppendingPathComponent:@"Documents/akc.plist"],
            [backupRoot stringByAppendingPathComponent:@"akc.plist"],
        ];
        BOOL akcDone = NO;
        for (NSString *akc in akcCandidates) {
            if ([fm fileExistsAtPath:akc]) {
                NSInteger n = [self restoreAKCPlistAtPath:akc];
                if (n > 0) {
                    akcDone = YES;
                    break;
                }
            }
        }
        if (!akcDone) {
            [self restoreKeychainHintsForApps:@[bid] fromRecord:recordName];
        }
    }
    return YES;
}

#pragma mark - AKC (AMG per-app Keychain snapshot)

- (CFTypeRef)secClassFromAKC:(NSString *)cls {
    if ([cls isEqualToString:@"inet"]) return kSecClassInternetPassword;
    if ([cls isEqualToString:@"cert"]) return kSecClassCertificate;
    if ([cls isEqualToString:@"keys"]) return kSecClassKey;
    if ([cls isEqualToString:@"idnt"]) return kSecClassIdentity;
    return kSecClassGenericPassword; // genp
}

- (id)accessibleFromPdmn:(NSString *)pdmn {
    if (!pdmn.length) return (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    // securityd pdmn codes commonly seen in dumps
    if ([pdmn isEqualToString:@"ak"] || [pdmn isEqualToString:@"aku"]) {
        return (__bridge id)kSecAttrAccessibleWhenUnlocked;
    }
    if ([pdmn isEqualToString:@"ck"] || [pdmn isEqualToString:@"cku"]) {
        return (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    }
    if ([pdmn isEqualToString:@"dk"] || [pdmn isEqualToString:@"dku"]) {
        return (__bridge id)kSecAttrAccessibleAlwaysThisDeviceOnly;
    }
    if ([pdmn isEqualToString:@"akpu"]) {
        return (__bridge id)kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly;
    }
    return (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
}

- (NSInteger)restoreAKCPlistAtPath:(NSString *)path {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![dict isKindOfClass:[NSDictionary class]] || !dict.count) return 0;

    NSInteger ok = 0;
    for (NSString *key in dict) {
        NSDictionary *item = dict[key];
        if (![item isKindOfClass:[NSDictionary class]]) continue;

        NSData *data = item[@"v_Data"];
        if (![data isKindOfClass:[NSData class]]) data = item[@"r_Data"];
        if (![data isKindOfClass:[NSData class]] || !data.length) continue;

        NSString *cls = [item[@"class"] isKindOfClass:[NSString class]] ? item[@"class"] : @"genp";
        CFTypeRef secClass = [self secClassFromAKC:cls];
        NSString *acct = [item[@"acct"] isKindOfClass:[NSString class]] ? item[@"acct"] : nil;
        NSString *svce = [item[@"svce"] isKindOfClass:[NSString class]] ? item[@"svce"] : nil;
        NSString *agrp = [item[@"agrp"] isKindOfClass:[NSString class]] ? item[@"agrp"] : nil;
        NSString *pdmn = [item[@"pdmn"] isKindOfClass:[NSString class]] ? item[@"pdmn"] : nil;

        NSMutableDictionary *query = [@{
            (__bridge id)kSecClass: (__bridge id)secClass,
        } mutableCopy];
        if (acct.length) query[(__bridge id)kSecAttrAccount] = acct;
        if (svce.length) query[(__bridge id)kSecAttrService] = svce;
        if (agrp.length) query[(__bridge id)kSecAttrAccessGroup] = agrp;

        SecItemDelete((__bridge CFDictionaryRef)query);

        NSMutableDictionary *add = [query mutableCopy];
        add[(__bridge id)kSecValueData] = data;
        add[(__bridge id)kSecAttrAccessible] = [self accessibleFromPdmn:pdmn];
        if (item[@"invi"]) {
            add[(__bridge id)kSecAttrIsInvisible] = @([item[@"invi"] boolValue]);
        }

        OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (st == errSecSuccess) {
            ok++;
        } else if (st == errSecDuplicateItem) {
            // Update existing
            NSDictionary *update = @{ (__bridge id)kSecValueData: data };
            if (SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update) == errSecSuccess) {
                ok++;
            }
        } else if (agrp.length) {
            // Retry without access group (some hosts reject foreign agrp)
            [add removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
            [query removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
            SecItemDelete((__bridge CFDictionaryRef)query);
            st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
            if (st == errSecSuccess || st == errSecDuplicateItem) ok++;
        }
    }
    return ok;
}

- (BOOL)backupAKCForBundleId:(NSString *)bid container:(NSString *)container toBackupRoot:(NSString *)backupRoot {
    // Dump queryable items that look owned by this app into AMG-compatible akc.plist.
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @YES,
    } mutableCopy];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        if (result) CFRelease(result);
        // Keep existing Documents/akc.plist if present
        return YES;
    }

    NSArray *arr = (__bridge_transfer NSArray *)result;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSDictionary *item in arr) {
        NSString *service = item[(__bridge id)kSecAttrService] ?: @"";
        NSString *account = item[(__bridge id)kSecAttrAccount] ?: @"";
        NSString *agrp = item[(__bridge id)kSecAttrAccessGroup] ?: @"";
        BOOL match = [service containsString:bid] || [account containsString:bid] || [agrp containsString:bid];
        if (!match) continue;

        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"class"] = @"genp";
        if (account.length) row[@"acct"] = account;
        if (service.length) row[@"svce"] = service;
        if (agrp.length) row[@"agrp"] = agrp;
        NSData *data = item[(__bridge id)kSecValueData];
        if (data) row[@"v_Data"] = data;
        row[@"pdmn"] = @"cku";
        NSString *key = [NSString stringWithFormat:@"%@_%@", service.length ? service : @"item", account.length ? account : @"acct"];
        out[key] = row;
    }

    if (!out.count) return YES;

    NSString *docs = [backupRoot stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *akcPath = [docs stringByAppendingPathComponent:@"akc.plist"];
    [out writeToFile:akcPath atomically:YES];

    // Also mirror into live container Documents when backing up from running app
    if (container.length) {
        NSString *liveDocs = [container stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:liveDocs withIntermediateDirectories:YES attributes:nil error:nil];
        // do not overwrite live app unless we are exporting; skip live write
    }
    return YES;
}

#pragma mark - Weak hints (fallback)

- (BOOL)backupKeychainHintsForApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName {
    for (NSString *bid in bundleIds) {
        NSMutableDictionary *query = [@{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecReturnData: @YES,
        } mutableCopy];
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        NSMutableArray *items = [NSMutableArray array];
        if (status == errSecSuccess && result) {
            NSArray *arr = (__bridge_transfer NSArray *)result;
            for (NSDictionary *item in arr) {
                NSString *service = item[(__bridge id)kSecAttrService] ?: @"";
                NSString *account = item[(__bridge id)kSecAttrAccount] ?: @"";
                if ([service containsString:bid] || [account containsString:bid]) {
                    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
                    copy[@"service"] = service;
                    copy[@"account"] = account;
                    NSData *data = item[(__bridge id)kSecValueData];
                    if (data) copy[@"data"] = [data base64EncodedStringWithOptions:0];
                    [items addObject:copy];
                }
            }
        } else if (result) {
            CFRelease(result);
        }
        NSString *path = [[NDPaths appsBackupDirForRecord:recordName bundleId:bid] stringByAppendingPathComponent:@"keychain-hints.plist"];
        NSString *dir = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [items writeToFile:path atomically:YES];
    }
    return YES;
}

- (BOOL)restoreKeychainHintsForApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName {
    for (NSString *bid in bundleIds) {
        NSString *path = [[NDPaths appsBackupDirForRecord:recordName bundleId:bid] stringByAppendingPathComponent:@"keychain-hints.plist"];
        NSArray *items = [NSArray arrayWithContentsOfFile:path];
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *item in items) {
            NSString *service = item[@"service"] ?: @"";
            NSString *account = item[@"account"] ?: @"";
            NSData *data = [[NSData alloc] initWithBase64EncodedString:item[@"data"] ?: @"" options:0];
            if (!service.length || !data) continue;
            NSDictionary *del = @{
                (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: service,
                (__bridge id)kSecAttrAccount: account,
            };
            SecItemDelete((__bridge CFDictionaryRef)del);
            NSDictionary *add = @{
                (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: service,
                (__bridge id)kSecAttrAccount: account,
                (__bridge id)kSecValueData: data,
            };
            SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        }
    }
    return YES;
}

@end
