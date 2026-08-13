#import "NDAMGImporter.h"
#import "NDDeviceProfile.h"
#import "NDRecordStore.h"
#import "NDConfig.h"
#import "NDPaths.h"
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

static NSString * const kNDAMGErrorDomain = @"NDAMGImporter";
static const NSInteger kNDAMGErrorHard = 1;
static const NSInteger kNDAMGErrorWarning = 2;

@implementation NDAMGImporter

+ (NSSet<NSString *> *)skippedRootNames {
    static NSSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"faker.plist", @"faker_plaintext.plist", @"profile.plist",
            @"selectApp.plist", @"description.plist", @"ifaddrs.plist",
            @"Pasteboard", @"AppGroup",
            @".DS_Store", @"KEYS.txt", @"README.txt",
        ]];
    });
    return set;
}

+ (void)runCommand:(NSString *)launchPath arguments:(NSArray<NSString *> *)args {
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

+ (BOOL)untar:(NSString *)archive into:(NSString *)dest error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSString *lower = archive.lowercaseString;
    BOOL gzip = [lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"];
    NSArray *args = gzip ? @[@"-xzf", archive, @"-C", dest] : @[@"-xf", archive, @"-C", dest];
    NSArray *bins = @[@"/usr/bin/tar", @"/var/jb/usr/bin/tar", @"/bin/tar"];
    for (NSString *bin in bins) {
        if ([fm isExecutableFileAtPath:bin]) {
            [self runCommand:bin arguments:args];
            NSArray *kids = [fm contentsOfDirectoryAtPath:dest error:nil];
            if (kids.count) return YES;
        }
    }
    if (error) {
        *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                userInfo:@{NSLocalizedDescriptionKey: @"Failed to unpack AMG tar"}];
    }
    return NO;
}

+ (BOOL)looksLikeCiphertext:(id)value {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *s = (NSString *)value;
    if (s.length < 24) return NO;
    if ([s containsString:@":"] || [s containsString:@"."]) return NO; // MAC / version-ish
    NSCharacterSet *b64 = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="];
    if ([s rangeOfCharacterFromSet:b64.invertedSet].location != NSNotFound) return NO;
    return [s containsString:@"="] || s.length >= 32;
}

+ (BOOL)dictionaryLooksEncrypted:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]] || !dict.count) return NO;
    NSInteger cipher = 0, total = 0;
    for (id key in dict) {
        id val = dict[key];
        if (![val isKindOfClass:[NSString class]]) continue;
        total++;
        if ([self looksLikeCiphertext:val]) cipher++;
    }
    return total > 0 && cipher * 2 >= total;
}

+ (BOOL)copyItem:(NSString *)src to:(NSString *)dst error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return YES;
    if ([fm fileExistsAtPath:dst]) {
        if (![fm removeItemAtPath:dst error:error]) return NO;
    }
    NSString *parent = [dst stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parent]) {
        if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    }
    return [fm copyItemAtPath:src toPath:dst error:error];
}

+ (BOOL)directoryLooksLikeAMGRecord:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return NO;
    for (NSString *name in @[@"faker.plist", @"selectApp.plist", @"faker_plaintext.plist", @"profile.plist"]) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:name]]) return YES;
    }
    return NO;
}

+ (NSDictionary *)loadPlaintextIdentityFromRecordDir:(NSString *)dir
                                         recordName:(NSString *)recordName
                                           warning:(NSString * _Nullable * _Nullable)warningOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *companions = @[
        @"faker_plaintext.plist",
        @"profile.plist",
        @"amg_param.plist",
        @"param.plist",
        @"01_plaintext_identity/faker_plaintext.plist",
        @"01_plaintext_identity/faker_plaintext.json",
        @"faker_plaintext.json",
    ];
    for (NSString *name in companions) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *dict = nil;
        if ([name.pathExtension.lowercaseString isEqualToString:@"json"]) {
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (data) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) dict = obj;
            }
        } else {
            dict = [NSDictionary dictionaryWithContentsOfFile:path];
        }
        if ([dict isKindOfClass:[NSDictionary class]] && dict.count && ![self dictionaryLooksEncrypted:dict]) {
            return dict;
        }
    }

    NSString *fakerPath = [dir stringByAppendingPathComponent:@"faker.plist"];
    NSDictionary *faker = [NSDictionary dictionaryWithContentsOfFile:fakerPath];
    if ([faker isKindOfClass:[NSDictionary class]] && faker.count && ![self dictionaryLooksEncrypted:faker]) {
        return faker;
    }

    // Best-effort: ask localhost AMG (or any listener) to dump plaintext via getRecordParam.
    if (recordName.length) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"nd_amg_param_%@.plist", [[NSUUID UUID] UUIDString]]];
        NSString *encName = [recordName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: recordName;
        NSString *encPath = [tmp stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: tmp;
        NSString *urlStr = [NSString stringWithFormat:@"http://127.0.0.1:8080/cmd?fun=getRecordParam&recordName=%@&saveFilePath=%@", encName, encPath];
        NSURL *url = [NSURL URLWithString:urlStr];
        if (url) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL finished = NO;
            [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(__unused NSData *data, __unused NSURLResponse *resp, __unused NSError *err) {
                finished = YES;
                dispatch_semaphore_signal(sem);
            }] resume];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
            if (finished || [fm fileExistsAtPath:tmp]) {
                // give AMG a moment to flush saveFilePath
                for (int i = 0; i < 10; i++) {
                    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:tmp];
                    if ([dict isKindOfClass:[NSDictionary class]] && dict.count && ![self dictionaryLooksEncrypted:dict]) {
                        [fm removeItemAtPath:tmp error:nil];
                        return dict;
                    }
                    [NSThread sleepForTimeInterval:0.15];
                }
            }
            [fm removeItemAtPath:tmp error:nil];
        }
    }

    if (warningOut) {
        *warningOut = @"faker.plist encrypted / no plaintext; profile fields partial";
    }
    return @{};
}

+ (void)mergeTargetApps:(NSArray *)apps {
    if (![apps isKindOfClass:[NSArray class]] || !apps.count) return;
    [[NDConfig shared] reload];
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:[NDConfig shared].targetApps ?: @[]];
    for (id item in apps) {
        if ([item isKindOfClass:[NSString class]] && [(NSString *)item length]) {
            [set addObject:item];
        }
    }
    [NDConfig shared].targetApps = set.array;
    [[NDConfig shared] save];
}

+ (BOOL)copyAppsFromAMGRecord:(NSString *)dir recordName:(NSString *)recordName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSSet *skip = [self skippedRootNames];

    for (NSString *entry in entries) {
        if ([skip containsObject:entry]) continue;
        NSString *srcRoot = [dir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:srcRoot isDirectory:&isDir] || !isDir) continue;
        // Bundle-id-ish folders only
        if (![entry containsString:@"."]) continue;

        NSString *dstRoot = [NDPaths appsBackupDirForRecord:recordName bundleId:entry];
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            NSString *src = [srcRoot stringByAppendingPathComponent:sub];
            NSString *dst = [dstRoot stringByAppendingPathComponent:sub];
            [self copyItem:src to:dst error:nil];
        }
    }

    NSString *appGroupRoot = [dir stringByAppendingPathComponent:@"AppGroup"];
    BOOL agDir = NO;
    if ([fm fileExistsAtPath:appGroupRoot isDirectory:&agDir] && agDir) {
        NSArray *bids = [fm contentsOfDirectoryAtPath:appGroupRoot error:nil] ?: @[];
        for (NSString *bid in bids) {
            if (![bid containsString:@"."]) continue;
            NSString *src = [appGroupRoot stringByAppendingPathComponent:bid];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:src isDirectory:&isDir] || !isDir) continue;
            NSString *dst = [[NDPaths appsBackupDirForRecord:recordName bundleId:bid] stringByAppendingPathComponent:@"AppGroup"];
            [self copyItem:src to:dst error:nil];
        }
    }
    return YES;
}

+ (BOOL)importFromAMGRecordDirectory:(NSString *)dir error:(NSError **)error {
    if (!dir.length) {
        if (error) *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                            userInfo:@{NSLocalizedDescriptionKey: @"Empty AMG record path"}];
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                            userInfo:@{NSLocalizedDescriptionKey: @"AMG record directory missing"}];
        return NO;
    }

    NSString *recordName = dir.lastPathComponent;
    if (!recordName.length || [recordName isEqualToString:@"/"] || [recordName isEqualToString:@"."]) {
        if (error) *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid record name"}];
        return NO;
    }

    NSString *warning = nil;
    NSDictionary *plain = [self loadPlaintextIdentityFromRecordDir:dir recordName:recordName warning:&warning];
    NDDeviceProfile *profile = [NDDeviceProfile profileFromDictionary:plain] ?: [NDDeviceProfile originalProfile];
    profile.name = recordName;
    profile.enabled = YES;
    if (!profile.createdAt) profile.createdAt = [NSDate date];

    NSArray *selectApps = [NSArray arrayWithContentsOfFile:[dir stringByAppendingPathComponent:@"selectApp.plist"]];
    [self mergeTargetApps:selectApps];

    if (![self copyAppsFromAMGRecord:dir recordName:recordName error:error]) {
        return NO;
    }

    if (![[NDRecordStore shared] saveProfile:profile error:error]) {
        return NO;
    }

    if (warning.length) {
        if (error) {
            *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorWarning
                                    userInfo:@{NSLocalizedDescriptionKey: warning}];
        }
    }
    return YES;
}

+ (NSArray<NSString *> *)discoverRecordDirsIn:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray array];
    if ([self directoryLooksLikeAMGRecord:root]) {
        [out addObject:root];
        return out;
    }
    NSArray *kids = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    for (NSString *name in kids) {
        NSString *path = [root stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) continue;
        if ([self directoryLooksLikeAMGRecord:path]) {
            [out addObject:path];
        } else {
            // one nesting level (tar often wraps a single folder)
            NSArray *grand = [fm contentsOfDirectoryAtPath:path error:nil] ?: @[];
            for (NSString *g in grand) {
                NSString *gp = [path stringByAppendingPathComponent:g];
                if ([self directoryLooksLikeAMGRecord:gp]) [out addObject:gp];
            }
        }
    }
    return out;
}

+ (BOOL)importArchive:(NSString *)archive preferredName:(NSString *)preferredName error:(NSError **)error {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"nd_amg_untar_%@", [[NSUUID UUID] UUIDString]]];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL ok = [self untar:archive into:tmp error:error];
    if (!ok) {
        [fm removeItemAtPath:tmp error:nil];
        return NO;
    }

    NSArray *records = [self discoverRecordDirsIn:tmp];
    if (!records.count) {
        // Flat extract: treat tmp itself as record if it has app folders / plists
        NSArray *entries = [fm contentsOfDirectoryAtPath:tmp error:nil] ?: @[];
        BOOL hasApp = NO;
        for (NSString *e in entries) {
            if ([e containsString:@"."] && ![e hasSuffix:@".plist"]) {
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:[tmp stringByAppendingPathComponent:e] isDirectory:&isDir] && isDir) {
                    hasApp = YES;
                    break;
                }
            }
        }
        if (hasApp || [fm fileExistsAtPath:[tmp stringByAppendingPathComponent:@"faker.plist"]]
            || [fm fileExistsAtPath:[tmp stringByAppendingPathComponent:@"selectApp.plist"]]) {
            // Move into a named folder so lastPathComponent becomes record name
            NSString *name = preferredName;
            if (!name.length) {
                name = archive.lastPathComponent;
                NSString *lower = name.lowercaseString;
                if ([lower hasSuffix:@".tar.gz"]) {
                    name = [name substringToIndex:name.length - 7];
                } else if ([lower hasSuffix:@".tgz"] || [lower hasSuffix:@".tar"]) {
                    name = name.stringByDeletingPathExtension;
                }
            }
            if (!name.length) name = [[NSUUID UUID] UUIDString];
            NSString *named = [tmp stringByAppendingPathComponent:name];
            // Relocate contents into named/
            [fm createDirectoryAtPath:named withIntermediateDirectories:YES attributes:nil error:nil];
            for (NSString *e in entries) {
                NSString *src = [tmp stringByAppendingPathComponent:e];
                NSString *dst = [named stringByAppendingPathComponent:e];
                if (![src isEqualToString:named]) {
                    [fm moveItemAtPath:src toPath:dst error:nil];
                }
            }
            records = @[named];
        }
    }

    if (!records.count) {
        [fm removeItemAtPath:tmp error:nil];
        if (error) {
            *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                    userInfo:@{NSLocalizedDescriptionKey: @"No AMG record found in archive"}];
        }
        return NO;
    }

    BOOL any = NO;
    NSMutableArray *warnings = [NSMutableArray array];
    for (NSString *rec in records) {
        NSError *err = nil;
        if ([self importFromAMGRecordDirectory:rec error:&err]) {
            any = YES;
            if (err) [warnings addObject:err.localizedDescription ?: @"warning"];
        } else if (err) {
            [warnings addObject:err.localizedDescription ?: @"import failed"];
        }
    }
    [fm removeItemAtPath:tmp error:nil];
    if (!any) {
        if (error) {
            *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                    userInfo:@{NSLocalizedDescriptionKey: warnings.firstObject ?: @"Import failed"}];
        }
        return NO;
    }
    if (warnings.count && error) {
        *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorWarning
                                userInfo:@{NSLocalizedDescriptionKey: [warnings componentsJoinedByString:@"; "]}];
    }
    return YES;
}

+ (BOOL)isTarPath:(NSString *)path {
    NSString *lower = path.lowercaseString;
    return [lower hasSuffix:@".tar"] || [lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"];
}

+ (BOOL)importFromPath:(NSString *)path recordName:(NSString *)recordName error:(NSError **)error {
    if (!path.length) {
        if (error) *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                            userInfo:@{NSLocalizedDescriptionKey: @"Empty path"}];
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (error) *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                            userInfo:@{NSLocalizedDescriptionKey: @"Path not found"}];
        return NO;
    }
    if (!isDir && [self isTarPath:path]) {
        return [self importArchive:path preferredName:recordName error:error];
    }
    if (isDir) {
        if ([self directoryLooksLikeAMGRecord:path]) {
            return [self importFromAMGRecordDirectory:path error:error];
        }
        // Container of records
        return [self importFromAMGTarDirectory:path error:error];
    }
    if (error) *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                        userInfo:@{NSLocalizedDescriptionKey: @"Unsupported AMG import path"}];
    return NO;
}

+ (BOOL)importFromAMGTarDirectory:(NSString *)amgTarRoot error:(NSError **)error {
    NSString *root = amgTarRoot.length ? amgTarRoot : @"/var/mobile/AMG_tar";
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        // Fallback: try live AMG records tree
        NSString *amgLive = @"/var/mobile/AMG";
        if ([fm fileExistsAtPath:amgLive isDirectory:&isDir] && isDir) {
            root = amgLive;
        } else {
            if (error) {
                *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AMG import root missing: %@", root]}];
            }
            return NO;
        }
    }

    if ([self directoryLooksLikeAMGRecord:root]) {
        return [self importFromAMGRecordDirectory:root error:error];
    }

    NSArray *entries = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    BOOL any = NO;
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *warnings = [NSMutableArray array];

    for (NSString *entry in entries) {
        NSString *path = [root stringByAppendingPathComponent:entry];
        BOOL entryDir = NO;
        [fm fileExistsAtPath:path isDirectory:&entryDir];
        NSError *err = nil;
        BOOL ok = NO;
        if (!entryDir && [self isTarPath:path]) {
            ok = [self importArchive:path preferredName:nil error:&err];
        } else if (entryDir && [self directoryLooksLikeAMGRecord:path]) {
            ok = [self importFromAMGRecordDirectory:path error:&err];
        } else if (entryDir) {
            NSArray *nested = [self discoverRecordDirsIn:path];
            for (NSString *rec in nested) {
                NSError *nerr = nil;
                if ([self importFromAMGRecordDirectory:rec error:&nerr]) {
                    ok = YES;
                    any = YES;
                    [names addObject:rec.lastPathComponent];
                    if (nerr) [warnings addObject:nerr.localizedDescription ?: @"warning"];
                }
            }
            continue;
        } else {
            continue;
        }
        if (ok) {
            any = YES;
            [names addObject:entry];
            if (err) [warnings addObject:err.localizedDescription ?: @"warning"];
        } else if (err) {
            [warnings addObject:err.localizedDescription ?: @"fail"];
        }
    }

    // Also pull already-unpacked live AMG records when scanning AMG_tar
    if ([root.lastPathComponent isEqualToString:@"AMG_tar"] || [root hasSuffix:@"/AMG_tar"]) {
        NSString *amgLive = @"/var/mobile/AMG";
        BOOL liveDir = NO;
        if ([fm fileExistsAtPath:amgLive isDirectory:&liveDir] && liveDir) {
            NSArray *live = [fm contentsOfDirectoryAtPath:amgLive error:nil] ?: @[];
            for (NSString *entry in live) {
                NSString *path = [amgLive stringByAppendingPathComponent:entry];
                if (![self directoryLooksLikeAMGRecord:path]) continue;
                if ([names containsObject:entry]) continue;
                NSError *err = nil;
                if ([self importFromAMGRecordDirectory:path error:&err]) {
                    any = YES;
                    [names addObject:entry];
                    if (err) [warnings addObject:err.localizedDescription ?: @"warning"];
                }
            }
        }
    }

    if (!any) {
        if (error) {
            *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorHard
                                    userInfo:@{NSLocalizedDescriptionKey: warnings.firstObject ?: @"No AMG packages found"}];
        }
        return NO;
    }
    if (warnings.count && error) {
        *error = [NSError errorWithDomain:kNDAMGErrorDomain code:kNDAMGErrorWarning
                                userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:@"Imported %lu; %@",
                                            (unsigned long)names.count,
                                            [warnings componentsJoinedByString:@"; "]]}];
    }
    return YES;
}

@end
