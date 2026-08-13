#import "NDRecordStore+ImportExport.h"
#import "NDRecordStore.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import "NDAppDataManager.h"
#import "NDDeviceProfile.h"
#import "NDArchiveExtract.h"

@implementation NDRecordStore (ImportExport)

+ (NSString *)amgTarPath { return @"/var/mobile/AMG_tar"; }
+ (NSString *)amgMediaImportPath { return @"/var/mobile/Media/AMG/import"; }
+ (NSString *)amgMediaExportPath { return @"/var/mobile/Media/AMG/export"; }
+ (NSString *)iGrimaceImportPath { return @"/var/mobile/iGrimace"; }
+ (NSString *)awzImportPath { return @"/var/mobile/importdata"; }

+ (BOOL)NDIsContainerFolderName:(NSString *)name {
    if (!name.length || [name hasPrefix:@"."]) return YES;
    NSString *lower = name.lowercaseString;
    return [lower isEqualToString:@"import"] || [lower isEqualToString:@"export"]
        || [lower isEqualToString:@"debs"] || [lower isEqualToString:@"amg"]
        || [lower isEqualToString:@"amg_tar"] || [lower isEqualToString:@"newdevice"];
}

+ (BOOL)NDPathLooksLikeAMGRecordDir:(NSString *)full {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:full isDirectory:&isDir] || !isDir) return NO;
    for (NSString *marker in @[@"faker.plist", @"profile.plist", @"description.plist", @"selectApp.plist",
                               @"faker_plaintext.plist", @"01_plaintext_identity", @"03_holographic_backups",
                               @"02_config_plists"]) {
        if ([fm fileExistsAtPath:[full stringByAppendingPathComponent:marker]]) return YES;
    }
    return NO;
}

/// Unwrap amg_extract / var/mobile/AMG / single-folder wrappers to the directory that
/// *contains* record folders (or is itself a record).
+ (NSString *)NDUnwrapImportRoot:(NSString *)dest {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cur = dest;
    for (NSInteger depth = 0; depth < 6; depth++) {
        NSArray *top = [fm contentsOfDirectoryAtPath:cur error:nil] ?: @[];
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        for (NSString *e in top) {
            if ([e hasPrefix:@"."]) continue;
            NSString *p = [cur stringByAppendingPathComponent:e];
            BOOL d = NO;
            if ([fm fileExistsAtPath:p isDirectory:&d] && d) [dirs addObject:p];
        }
        // If any child is a record dir, cur is the import root
        for (NSString *p in dirs) {
            if ([self NDPathLooksLikeAMGRecordDir:p]) return cur;
        }
        // Prefer known wrappers
        NSString *wrapper = nil;
        for (NSString *p in dirs) {
            NSString *leaf = p.lastPathComponent.lowercaseString;
            if ([leaf isEqualToString:@"amg_extract"] || [leaf isEqualToString:@"amg"] || [leaf isEqualToString:@"amg_tar"]
                || [leaf isEqualToString:@"var"] || [leaf isEqualToString:@"private"]) {
                wrapper = p;
                break;
            }
        }
        if (wrapper) {
            cur = wrapper;
            continue;
        }
        // Single directory → descend
        if (dirs.count == 1) {
            cur = dirs.firstObject;
            continue;
        }
        break;
    }
    return dest;
}

+ (BOOL)NDDirectoryLooksImportable:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return NO;
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    for (NSString *entry in entries) {
        if ([self NDIsContainerFolderName:entry]) continue;
        NSString *lower = entry.lowercaseString;
        if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"] || [lower hasSuffix:@".tar"] || [lower hasSuffix:@".zip"]) return YES;
        if ([lower hasSuffix:@".plist"] && ![lower isEqualToString:@"description.plist"] && ![lower isEqualToString:@"selectapp.plist"]) return YES;
        NSString *full = [dir stringByAppendingPathComponent:entry];
        BOOL entryDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&entryDir] || !entryDir) continue;
        if ([self NDPathLooksLikeAMGRecordDir:full]) return YES;
        // Wrapper like amg_extract/
        if ([self NDPathLooksLikeAMGRecordDir:[self NDUnwrapImportRoot:full]] ||
            [self NDPathLooksLikeAMGRecordDir:[[self NDUnwrapImportRoot:full] stringByAppendingPathComponent:entry]]) {
            // unwrap may point at parent; also check children of wrapper
            NSArray *kids = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
            for (NSString *k in kids) {
                if ([self NDPathLooksLikeAMGRecordDir:[full stringByAppendingPathComponent:k]]) return YES;
            }
        }
        NSArray *kids = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
        for (NSString *k in kids) {
            if ([self NDPathLooksLikeAMGRecordDir:[full stringByAppendingPathComponent:k]]) return YES;
        }
    }
    return NO;
}

+ (NSString *)resolvedAMGImportPath {
    // Prefer directories that actually contain importable content.
    // Never scan parent Media/AMG or Media/NewDevice — their import/export children
    // used to be mistaken for machine records.
    NSArray *candidates = @[
        [NDPaths mediaImportDir],
        [self amgMediaImportPath],
        [self amgTarPath],
        // Runtime tree last — faker often at-rest ciphertext; only use if nothing else
        @"/var/mobile/AMG",
    ];
    NSString *emptyPreferred = nil;
    for (NSString *p in candidates) {
        if ([self NDDirectoryLooksImportable:p]) return p;
        BOOL isDir = NO;
        if (!emptyPreferred && [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            emptyPreferred = p;
        }
    }
    return emptyPreferred ?: [NDPaths mediaImportDir];
}

- (NSUInteger)NDImportUnpackedTree:(NSString *)dir
                     importKeychain:(BOOL)importKeychain
                              error:(NSError **)error {
    BOOL prev = [NDConfig shared].importKeychainWithData;
    [NDConfig shared].importKeychainWithData = importKeychain;
    NSUInteger n = [self importAMGRecordsFromDirectory:dir error:error];
    [NDConfig shared].importKeychainWithData = prev;
    return n;
}

- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir
                              importKeychain:(BOOL)importKeychain
                                       error:(NSError **)error {
    if (!dir.length) dir = [[self class] resolvedAMGImportPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:30 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AMG 导入目录不存在: %@\n请把 AMG「导出」的包放到 /var/mobile/AMG_tar", dir]}];
        return 0;
    }

    [self beginImportSession];
    NSUInteger total = 0;

    // 1) Folder trees
    {
        NSError *err = nil;
        NSUInteger n = [self NDImportUnpackedTree:dir importKeychain:importKeychain error:&err];
        total += n;
        if (error && err) *error = err;
    }

    // 2) Archives in AMG_tar (skip if same basename already present as folder)
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    // Prefer Media path (writable via Aisi / AFC); fall back to tmp
    NSString *scratchRoot = @"/var/mobile/Media/AMG/.nd-extract";
    if (![fm createDirectoryAtPath:scratchRoot withIntermediateDirectories:YES attributes:nil error:nil]) {
        scratchRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nd-amg-import"];
        [fm createDirectoryAtPath:scratchRoot withIntermediateDirectories:YES attributes:nil error:nil];
    }

    for (NSString *entry in entries) {
        NSString *lower = entry.lowercaseString;
        BOOL isArchive = [lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"] || [lower hasSuffix:@".tar"] || [lower hasSuffix:@".zip"];
        if (!isArchive) continue;

        // Skip archive if an unpacked sibling folder with same logical name exists
        NSString *base = entry;
        if ([lower hasSuffix:@".tar.gz"]) base = [entry substringToIndex:entry.length - 7];
        else base = [entry stringByDeletingPathExtension];
        NSString *sibling = [dir stringByAppendingPathComponent:base];
        BOOL siblingDir = NO;
        if ([fm fileExistsAtPath:sibling isDirectory:&siblingDir] && siblingDir) continue;

        NSString *archive = [dir stringByAppendingPathComponent:entry];
        NSString *dest = [scratchRoot stringByAppendingPathComponent:base];
        [fm removeItemAtPath:dest error:nil];
        NSError *exErr = nil;
        if (!NDExtractArchiveToDirectory(archive, dest, &exErr)) {
            if (error) {
                *error = [NSError errorWithDomain:@"NDRecordStore" code:32 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法解压 %@\n%@\n建议：在电脑解压后，把记录文件夹直接放进\n/var/mobile/Media/AMG/import/", entry, exErr.localizedDescription ?: @""]}];
            }
            continue;
        }

        NSString *importRoot = [self NDUnwrapImportRoot:dest];
        // If unwrap landed on a single record dir, import its parent so the record is one entry
        if ([self NDPathLooksLikeAMGRecordDir:importRoot] &&
            ![self NDPathLooksLikeAMGRecordDir:dest]) {
            // keep parent that contains the record folder
            NSString *parent = [importRoot stringByDeletingLastPathComponent];
            if (parent.length) importRoot = parent;
        }
        // Common nested roots
        for (NSString *nested in @[@"var/mobile/AMG", @"var/mobile/AMG_tar", @"AMG", @"AMG_tar", @"amg_extract"]) {
            NSString *p = [dest stringByAppendingPathComponent:nested];
            if ([fm fileExistsAtPath:p]) {
                // Prefer amg_extract / AMG when it contains record children
                NSArray *kids = [fm contentsOfDirectoryAtPath:p error:nil] ?: @[];
                for (NSString *k in kids) {
                    if ([self NDPathLooksLikeAMGRecordDir:[p stringByAppendingPathComponent:k]]) {
                        importRoot = p;
                        break;
                    }
                }
            }
        }
        total += [self NDImportUnpackedTree:importRoot importKeychain:importKeychain error:nil];
    }

    [fm removeItemAtPath:scratchRoot error:nil];

    [self endImportSession];
    if (total == 0 && error && !*error) {
        *error = [NSError errorWithDomain:@"NDRecordStore" code:31 userInfo:@{NSLocalizedDescriptionKey: @"未找到可导入的 AMG 记录。请使用 AMG「导出 AMG 数据」得到的包放到 /var/mobile/AMG_tar，不要只拷运行时目录 /var/mobile/AMG（其中 faker.plist 为落盘密文）。"}];
    }
    return total;
}

- (NSUInteger)importForeignRecordsFromDirectory:(NSString *)dir
                                           kind:(NSString *)kind
                                  importKeychain:(BOOL)importKeychain
                                           error:(NSError **)error {
    if (!dir.length) {
        if ([kind.lowercaseString containsString:@"awz"]) dir = [NDRecordStore awzImportPath];
        else if ([kind.lowercaseString containsString:@"grimace"] || [kind.lowercaseString containsString:@"igrimace"]) dir = [NDRecordStore iGrimaceImportPath];
        else dir = [NDRecordStore resolvedAMGImportPath];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:30 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ 目录不存在: %@", kind ?: @"数据", dir]}];
        return 0;
    }
    if ([kind.lowercaseString containsString:@"amg"]) {
        return [self importAMGRecordsFromDirectory:dir importKeychain:importKeychain error:error];
    }
    return [self NDImportUnpackedTree:dir importKeychain:importKeychain error:error];
}

- (BOOL)NDCopyTree:(NSString *)src to:(NSString *)dst {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return YES;
    [fm removeItemAtPath:dst error:nil];
    NSString *parent = [dst stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    return [fm copyItemAtPath:src toPath:dst error:nil];
}

- (NSUInteger)exportAMGRecordsToDirectory:(NSString *)dir
                                     slim:(BOOL)slim
                                    error:(NSError **)error {
    // Default to Aisi-visible NewDevice export folder
    if (!dir.length) dir = [NDPaths mediaExportDir];
    NSFileManager *fm = [NSFileManager defaultManager];
    [NDPaths ensureDirectories];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return 0;

    // Stage folders under Media so packing works even if AMG_tar is awkward to browse in Aisi
    NSString *stageRoot = [[NDPaths mediaHomeDir] stringByAppendingPathComponent:@".nd-export-stage"];
    [fm removeItemAtPath:stageRoot error:nil];
    [fm createDirectoryAtPath:stageRoot withIntermediateDirectories:YES attributes:nil error:nil];

    NSUInteger exported = 0;
    NSArray *names = [self allRecordNames];
    NSArray *apps = [NDConfig shared].targetApps ?: @[];
    // Mirror destinations (Aisi can see Media/*)
    NSArray *mirrorDirs = @[
        dir,
        [NDPaths mediaExportDir],
        [NDRecordStore amgMediaExportPath],
        [NDRecordStore amgTarPath],
    ];
    NSMutableSet *uniqueMirrors = [NSMutableSet set];
    for (NSString *d in mirrorDirs) {
        if (!d.length) continue;
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        [uniqueMirrors addObject:d];
    }

    for (NSString *name in names) {
        if ([name isEqualToString:@"原始机器"]) continue;
        NDDeviceProfile *p = [self profileNamed:name];
        if (!p) continue;
        // Sanitize filename for tar
        NSString *safe = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]] componentsJoinedByString:@"_"];
        if (!safe.length) safe = @"record";
        NSString *out = [stageRoot stringByAppendingPathComponent:safe];
        [fm removeItemAtPath:out error:nil];
        if (![p writeAMGFakerToDirectory:out error:nil]) continue;

        // Also copy NewDevice native profile.plist for round-trip
        NSString *profileSrc = [NDPaths profilePathForRecord:name];
        if ([fm fileExistsAtPath:profileSrc]) {
            [fm copyItemAtPath:profileSrc toPath:[out stringByAppendingPathComponent:@"profile.plist"] error:nil];
        }

        NSDictionary *desc = @{
            @"title": name,
            @"appName": apps ?: @[],
        };
        [desc writeToFile:[out stringByAppendingPathComponent:@"description.plist"] atomically:YES];
        [apps writeToFile:[out stringByAppendingPathComponent:@"selectApp.plist"] atomically:YES];

        NSString *ifa = [NDPaths ifaddrsPathForRecord:name];
        if ([fm fileExistsAtPath:ifa]) {
            [self NDCopyTree:ifa to:[out stringByAppendingPathComponent:@"ifaddrs.plist"]];
        }
        NSString *pb = [NDPaths pasteboardDirForRecord:name];
        if ([fm fileExistsAtPath:pb]) {
            [self NDCopyTree:pb to:[out stringByAppendingPathComponent:@"Pasteboard"]];
        }
        NSString *ag = [[NDPaths recordDir:name] stringByAppendingPathComponent:@"AppGroup"];
        if ([fm fileExistsAtPath:ag]) {
            [self NDCopyTree:ag to:[out stringByAppendingPathComponent:@"AppGroup"]];
        }

        for (NSString *bid in apps) {
            NSString *src = [NDPaths appsBackupDirForRecord:name bundleId:bid];
            if (![fm fileExistsAtPath:src]) continue;
            NSString *dst = [out stringByAppendingPathComponent:bid];
            [self NDCopyTree:src to:dst];
        }

        if (slim || [NDConfig shared].slimExportStripMedia) {
            [[NDAppDataManager shared] slimMediaInDirectory:out];
        }

        // Pack as uncompressed .tar
        NSString *tarName = [safe stringByAppendingPathExtension:@"tar"];
        NSString *primaryTar = [dir stringByAppendingPathComponent:tarName];
        [fm removeItemAtPath:primaryTar error:nil];

        NSError *tarErr = nil;
        if (!NDCreateTarFromDirectory(out, primaryTar, &tarErr)) {
            NSString *folderDst = [dir stringByAppendingPathComponent:safe];
            [fm removeItemAtPath:folderDst error:nil];
            [self NDCopyTree:out to:folderDst];
            if (error && !*error) *error = tarErr;
        } else {
            for (NSString *mirror in uniqueMirrors) {
                if ([mirror isEqualToString:dir]) continue;
                NSString *copyTo = [mirror stringByAppendingPathComponent:tarName];
                [fm removeItemAtPath:copyTo error:nil];
                [fm copyItemAtPath:primaryTar toPath:copyTo error:nil];
            }
        }
        exported++;
    }
    [fm removeItemAtPath:stageRoot error:nil];
    return exported;
}

- (BOOL)slimRecord:(NSString *)name error:(NSError **)error {
    if (!name.length) return NO;
    NSString *root = [NDPaths recordDir:name];
    [[NDAppDataManager shared] slimMediaInDirectory:root];
    return YES;
}

@end
