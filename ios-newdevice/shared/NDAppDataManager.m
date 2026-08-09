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
        // killall by executable name is fragile; use launchctl / killall best-effort
        [self runCommand:@"/var/jb/usr/bin/killall" arguments:@[@"-9", bid.lastPathComponent]];
        [self runCommand:@"/usr/bin/killall" arguments:@[@"-9", bid.lastPathComponent]];
    }
    // Also try sbutils-style via bash kill by bundle through `killall` of common names
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

@end
