#import "NDAppDataManager.h"
#import "NDPaths.h"
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

- (NSString *)containerPathForBundleId:(NSString *)bundleId {
    // Prefer lsappinfo / private API when available; fallback to Application scanning
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

    // Fallback: search mobile containers (slow, best-effort)
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

- (BOOL)restoreApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *bid in bundleIds) {
        NSString *container = [self containerPathForBundleId:bid];
        if (!container) continue;
        NSString *backupRoot = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
        if (![fm fileExistsAtPath:backupRoot]) {
            // no backup: clear instead
            [self clearDataForApps:@[bid] error:nil];
            continue;
        }
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            NSString *src = [backupRoot stringByAppendingPathComponent:sub];
            NSString *dst = [container stringByAppendingPathComponent:sub];
            [self copyItem:src to:dst error:nil];
        }
        [self restoreKeychainHintsForApps:@[bid] fromRecord:recordName];
    }
    [self restoreAppGroupsForRecord:recordName];
    return YES;
}

- (BOOL)backupKeychainHintsForApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName {
    // Best-effort: dump queryable generic passwords filtered by service containing bundle id.
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

- (NSString *)sharedAppGroupPathForGroupId:(NSString *)groupId {
    if (!groupId.length) return nil;
    NSString *root = @"/var/mobile/Containers/Shared/AppGroup";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    for (NSString *uuid in uuids) {
        NSString *meta = [[root stringByAppendingPathComponent:uuid] stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([plist[@"MCMMetadataIdentifier"] isEqualToString:groupId]) {
            return [root stringByAppendingPathComponent:uuid];
        }
    }
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
        skip = [NSSet setWithArray:@[@"AppGroup", @"Pasteboard", @"Documents", @"Library", @"tmp"]];
    });

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
        for (NSString *sub in @[@"Documents", @"Library", @"tmp", @"SystemData"]) {
            NSString *src = [srcRoot stringByAppendingPathComponent:sub];
            if (![fm fileExistsAtPath:src]) continue;
            [self copyItem:src to:[dstRoot stringByAppendingPathComponent:sub] error:nil];
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
        }
    }
    return YES;
}

@end
