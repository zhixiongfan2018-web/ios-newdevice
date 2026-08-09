#import "NDAppDataManager.h"
#import "NDPaths.h"
#import <objc/message.h>
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

- (int)runCommand:(NSString *)launchPath arguments:(NSArray<NSString *> *)args {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:launchPath]) {
        return -1;
    }
    pid_t pid = 0;
    const char *path = launchPath.fileSystemRepresentation;
    NSUInteger count = args.count;
    char **argv = calloc(count + 2, sizeof(char *));
    if (!argv) return -1;
    argv[0] = (char *)path;
    for (NSUInteger i = 0; i < count; i++) {
        argv[i + 1] = (char *)args[i].UTF8String;
    }
    argv[count + 1] = NULL;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc == 0 && pid > 0) {
        int status = 0;
        waitpid(pid, &status, 0);
        free(argv);
        if (WIFEXITED(status)) return WEXITSTATUS(status);
        return status;
    }
    free(argv);
    return rc == 0 ? -1 : rc;
}

- (nullable id)applicationProxyForBundleId:(NSString *)bundleId {
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (!LSApplicationProxy) return nil;
    SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![LSApplicationProxy respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(LSApplicationProxy, sel, bundleId);
}

- (NSString *)executableNameForBundleId:(NSString *)bundleId {
    if (!bundleId.length) return nil;
    id proxy = [self applicationProxyForBundleId:bundleId];
    if (proxy) {
        SEL execNameSel = NSSelectorFromString(@"executableName");
        if ([proxy respondsToSelector:execNameSel]) {
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, execNameSel);
            if ([name isKindOfClass:[NSString class]] && name.length) return name;
        }
        for (NSString *selName in @[@"bundleURL", @"bundleContainerURL"]) {
            SEL sel = NSSelectorFromString(selName);
            if (![proxy respondsToSelector:sel]) continue;
            NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, sel);
            if (![url isKindOfClass:[NSURL class]] || !url.path.length) continue;
            NSString *infoPath = [url.path stringByAppendingPathComponent:@"Info.plist"];
            // Some proxies return .app container root already; also try Contents-less iOS layout.
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            if (!info) {
                // If URL is the .app itself, Info.plist is direct; if parent, scan *.app
                NSArray *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:url.path error:nil];
                for (NSString *child in children) {
                    if ([child.pathExtension.lowercaseString isEqualToString:@"app"]) {
                        info = [NSDictionary dictionaryWithContentsOfFile:[[url.path stringByAppendingPathComponent:child] stringByAppendingPathComponent:@"Info.plist"]];
                        if (info) break;
                    }
                }
            }
            NSString *exec = info[@"CFBundleExecutable"];
            if ([exec isKindOfClass:[NSString class]] && exec.length) return exec;
        }
    }
    // Last path component of a reverse-DNS id is rarely the process name; still try as fallback.
    return bundleId.lastPathComponent;
}

- (void)killExecutableNamed:(NSString *)execName {
    if (!execName.length) return;
    NSArray<NSString *> *bins = @[
        @"/var/jb/usr/bin/killall",
        @"/usr/bin/killall",
        @"/var/jb/bin/killall",
        @"/bin/killall",
    ];
    for (NSString *bin in bins) {
        [self runCommand:bin arguments:@[@"-9", execName]];
    }
}

- (void)terminateApps:(NSArray<NSString *> *)bundleIds {
    for (NSString *bid in bundleIds) {
        if (!bid.length) continue;
        NSString *execName = [self executableNameForBundleId:bid];
        if (execName.length) {
            [self killExecutableNamed:execName];
        }
        // Workspace private terminate when available (SpringBoard-side).
        Class LSApplicationWorkspace = NSClassFromString(@"LSApplicationWorkspace");
        SEL defSel = NSSelectorFromString(@"defaultWorkspace");
        if (LSApplicationWorkspace && [LSApplicationWorkspace respondsToSelector:defSel]) {
            id workspace = ((id (*)(id, SEL))objc_msgSend)(LSApplicationWorkspace, defSel);
            SEL termSel = NSSelectorFromString(@"terminateApplication:withOptions:error:");
            if (workspace && [workspace respondsToSelector:termSel]) {
                NSError *err = nil;
                ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(workspace, termSel, bid, @{}, &err);
            }
        }
    }
    // Give processes a brief moment to exit before sandbox IO.
    [NSThread sleepForTimeInterval:0.35];
}

- (NSString *)containerPathForBundleId:(NSString *)bundleId {
    id proxy = [self applicationProxyForBundleId:bundleId];
    if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")]) {
        NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"dataContainerURL"));
        if ([url isKindOfClass:[NSURL class]] && url.path.length) return url.path;
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
    NSError *lastError = nil;
    for (NSString *bid in bundleIds) {
        NSString *container = [self containerPathForBundleId:bid];
        if (!container) continue;
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            NSString *path = [container stringByAppendingPathComponent:sub];
            if ([fm fileExistsAtPath:path]) {
                NSError *err = nil;
                if (![fm removeItemAtPath:path error:&err]) {
                    lastError = err;
                    continue;
                }
                [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
            }
        }
    }
    if (lastError && error) *error = lastError;
    return lastError == nil;
}

- (BOOL)backupApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName error:(NSError **)error {
    NSError *lastError = nil;
    for (NSString *bid in bundleIds) {
        NSString *container = [self containerPathForBundleId:bid];
        if (!container) continue;
        NSString *backupRoot = [NDPaths appsBackupDirForRecord:recordName bundleId:bid];
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            NSString *src = [container stringByAppendingPathComponent:sub];
            NSString *dst = [backupRoot stringByAppendingPathComponent:sub];
            NSError *err = nil;
            if (![self copyItem:src to:dst error:&err] && err) {
                lastError = err;
            }
        }
        [self backupKeychainHintsForApps:@[bid] toRecord:recordName];
    }
    if (lastError && error) *error = lastError;
    // Partial backup still counts as soft-success for holographic chain continuity.
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
