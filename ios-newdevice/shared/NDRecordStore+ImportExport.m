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

/// Classic runtime / desktop export layout AMG itself recognizes under /var/mobile/AMG/<name>/.
/// Must have real holographic content — description-only folders are NOT classic (they create empty shells).
+ (BOOL)NDPathLooksLikeClassicAMGRecordDir:(NSString *)full {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:full isDirectory:&isDir] || !isDir) return NO;
    BOOL has01 = [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"01_plaintext_identity"]];
    BOOL has03 = [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"03_holographic_backups"]];
    if (has01 || has03) return NO; // resolved analysis layout
    BOOL hasFaker = [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"faker.plist"]];
    NSString *venmo = [full stringByAppendingPathComponent:@"net.kortina.labs.Venmo"];
    BOOL hasVenmoAkc = [fm fileExistsAtPath:[[venmo stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"akc.plist"]];
    if (hasVenmoAkc) return YES;
    if (!hasFaker) return NO;
    // faker + at least one bid folder with Documents/
    NSArray *kids = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
    for (NSString *k in kids) {
        if ([k rangeOfString:@"."].location == NSNotFound) continue;
        if ([k.pathExtension.lowercaseString isEqualToString:@"plist"]) continue;
        NSString *docs = [[full stringByAppendingPathComponent:k] stringByAppendingPathComponent:@"Documents"];
        BOOL d = NO;
        if ([fm fileExistsAtPath:docs isDirectory:&d] && d) return YES;
    }
    return NO;
}

+ (BOOL)NDPathLooksLikeResolvedAMGRecordDir:(NSString *)full {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"01_plaintext_identity"]]
        || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"03_holographic_backups"]];
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

/// Cursor/Aisi renames often break ".tar.gz" into ".tar_xxxx.gz" — still import those.
+ (BOOL)NDEntryLooksLikeArchive:(NSString *)entry path:(NSString *)fullPath {
    if (!entry.length) return NO;
    NSString *lower = entry.lowercaseString;
    if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"] || [lower hasSuffix:@".tar"] || [lower hasSuffix:@".zip"]) return YES;
    // Any .gz: treat as archive (AMG packs are gzip). Avoid NSFileHandle edge cases.
    if ([lower hasSuffix:@".gz"]) return YES;
    (void)fullPath;
    return NO;
}

+ (NSString *)NDArchiveLogicalBaseName:(NSString *)entry {
    NSString *lower = entry.lowercaseString;
    if ([lower hasSuffix:@".tar.gz"]) return [entry substringToIndex:entry.length - 7];
    if ([lower hasSuffix:@".tgz"]) return [entry substringToIndex:entry.length - 4];
    // AMG_resolved_….tar_ae77.gz → strip final .gz then trailing .tar_* / .tar
    if ([lower hasSuffix:@".gz"]) {
        NSString *noGz = [entry substringToIndex:entry.length - 3];
        NSString *noGzLower = noGz.lowercaseString;
        if ([noGzLower hasSuffix:@".tar"]) return [noGz substringToIndex:noGz.length - 4];
        NSRange r = [noGzLower rangeOfString:@".tar_" options:NSBackwardsSearch];
        if (r.location != NSNotFound) return [noGz substringToIndex:r.location];
        return noGz;
    }
    return [entry stringByDeletingPathExtension];
}

+ (void)NDWriteImportLog:(NSString *)text {
    if (!text.length) return;
    NSArray *paths = @[
        @"/var/mobile/Media/AMG/import/nd-last-import.txt",
        @"/var/mobile/Media/NewDevice/import/nd-last-import.txt",
        @"/var/mobile/AMG_tar/nd-last-import.txt",
        @"/var/mobile/Library/Logs/CrashReporter/nd-last-import.txt",
    ];
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterShortStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    NSString *body = [NSString stringWithFormat:@"%@\n%@\n", stamp, text];
    for (NSString *p in paths) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [body writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

+ (BOOL)NDDirectoryLooksImportable:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return NO;
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    for (NSString *entry in entries) {
        if ([self NDIsContainerFolderName:entry]) continue;
        NSString *full = [dir stringByAppendingPathComponent:entry];
        NSString *lower = entry.lowercaseString;
        if ([self NDEntryLooksLikeArchive:entry path:full]) return YES;
        if ([lower hasSuffix:@".plist"] && ![lower isEqualToString:@"description.plist"] && ![lower isEqualToString:@"selectapp.plist"]) return YES;
        BOOL entryDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&entryDir] || !entryDir) continue;
        if ([self NDPathLooksLikeAMGRecordDir:full]) return YES;
        // Wrapper like amg_extract/
        NSString *unwrapped = [self NDUnwrapImportRoot:full];
        if ([self NDPathLooksLikeAMGRecordDir:unwrapped]) return YES;
        NSArray *kids = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
        for (NSString *k in kids) {
            if ([self NDPathLooksLikeAMGRecordDir:[full stringByAppendingPathComponent:k]]) return YES;
        }
        // Unwrapped root may be the wrapper itself containing record children
        kids = [fm contentsOfDirectoryAtPath:unwrapped error:nil] ?: @[];
        for (NSString *k in kids) {
            if ([self NDPathLooksLikeAMGRecordDir:[unwrapped stringByAppendingPathComponent:k]]) return YES;
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
    NSString *root = dir;
    NSString *unwrapped = [[self class] NDUnwrapImportRoot:dir];
    if (unwrapped.length) {
        // Prefer directory that *contains* record folders
        if ([[self class] NDPathLooksLikeAMGRecordDir:unwrapped]) {
            NSString *parent = [unwrapped stringByDeletingLastPathComponent];
            root = parent.length ? parent : unwrapped;
        } else {
            root = unwrapped;
        }
    }
    NSUInteger n = [self importAMGRecordsFromDirectory:root error:error];
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
        NSString *msg = [NSString stringWithFormat:
                         @"AMG 导入目录不存在: %@\n请把桌面经典包（如 +1916… 2026-….tar.gz）放到\n/var/mobile/Media/AMG/import\n"
                         @"（AMG 只认 /var/mobile/AMG/<记录名>/；AMG_resolved 是分析包不能写回）", dir];
        [[self class] NDWriteImportLog:msg];
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:30 userInfo:@{NSLocalizedDescriptionKey: msg}];
        return 0;
    }

    [self beginImportSession];
    NSUInteger total = 0;
    NSMutableArray *log = [NSMutableArray array];
    [log addObject:[@"scanDir=" stringByAppendingString:dir ?: @""]];

    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    [log addObject:[NSString stringWithFormat:@"entries=%lu", (unsigned long)entries.count]];
    for (NSString *e in entries) {
        [log addObject:[@"  - " stringByAppendingString:e ?: @""]];
    }

    @try {
        // 1) Classic folders already on disk → install to /var/mobile/AMG/<记录名>/ + NewDevice
        {
            NSMutableArray<NSString *> *classicRoots = [NSMutableArray array];
            void (^collectClassic)(NSString *) = ^(NSString *root) {
                NSArray *kids = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
                for (NSString *k in kids) {
                    if ([k hasPrefix:@"."]) continue;
                    NSString *kp = [root stringByAppendingPathComponent:k];
                    if ([[self class] NDPathLooksLikeClassicAMGRecordDir:kp]) {
                        // Skip resolved-only analysis trees
                        if ([[self class] NDPathLooksLikeResolvedAMGRecordDir:kp]
                            && ![fm fileExistsAtPath:[kp stringByAppendingPathComponent:@"faker.plist"]]) {
                            continue;
                        }
                        if (![classicRoots containsObject:kp]) [classicRoots addObject:kp];
                    }
                }
            };
            collectClassic(dir);
            NSString *unwrapped = [[self class] NDUnwrapImportRoot:dir];
            if (unwrapped.length && ![unwrapped isEqualToString:dir]) collectClassic(unwrapped);
            for (NSString *nested in @[@"amg_extract", @"AMG", @"var/mobile/AMG"]) {
                NSString *p = [dir stringByAppendingPathComponent:nested];
                BOOL d = NO;
                if ([fm fileExistsAtPath:p isDirectory:&d] && d) collectClassic(p);
            }
            NSUInteger classicN = 0;
            for (NSString *kp in classicRoots) {
                NSString *note = nil;
                NSError *oneErr = nil;
                BOOL ok = NO;
                @try {
                    ok = [self importClassicAMGRecordAtPath:kp note:&note error:&oneErr];
                } @catch (NSException *ex) {
                    note = [NSString stringWithFormat:@"exception %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"];
                    ok = NO;
                }
                [log addObject:[NSString stringWithFormat:@"folderClassic=%@ ok=%@ note=%@",
                                kp.lastPathComponent, ok ? @"YES" : @"NO", note ?: (oneErr.localizedDescription ?: @"")]];
                if (ok) classicN++;
            }
            total += classicN;
            [log addObject:[NSString stringWithFormat:@"folderClassicImport=%lu", (unsigned long)classicN]];
        }

        // 2) Remaining folder trees (resolved analysis / leftovers)
        if (total == 0) {
            NSError *err = nil;
            NSUInteger n = [self NDImportUnpackedTree:dir importKeychain:importKeychain error:&err];
            total += n;
            [log addObject:[NSString stringWithFormat:@"folderImport=%lu", (unsigned long)n]];
            if (error && err) *error = err;
        } else {
            [log addObject:@"folderImport=skipped (classic live install already succeeded)"];
        }

        // 3) Archives (accept mangled .tar_*.gz names from chat/Aisi)
        NSString *scratchRoot = @"/var/mobile/Media/AMG/.nd-extract";
        if (![fm createDirectoryAtPath:scratchRoot withIntermediateDirectories:YES attributes:nil error:nil]) {
            scratchRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nd-amg-import"];
            [fm createDirectoryAtPath:scratchRoot withIntermediateDirectories:YES attributes:nil error:nil];
        }

        for (NSString *entry in entries) {
            NSString *archive = [dir stringByAppendingPathComponent:entry];
            if (![[self class] NDEntryLooksLikeArchive:entry path:archive]) continue;

            NSString *base = [[self class] NDArchiveLogicalBaseName:entry];
            if (!base.length) base = @"amg-pack";
            // Sanitize + in extract folder names (some FS tools choke)
            base = [[base stringByReplacingOccurrencesOfString:@"+" withString:@""]
                    stringByReplacingOccurrencesOfString:@" " withString:@"_"];
            NSString *sibling = [dir stringByAppendingPathComponent:[[self class] NDArchiveLogicalBaseName:entry]];
            BOOL siblingDir = NO;
            if ([fm fileExistsAtPath:sibling isDirectory:&siblingDir] && siblingDir) {
                [log addObject:[@"skipArchive sibling: " stringByAppendingString:entry ?: @""]];
                continue;
            }

            NSString *dest = [scratchRoot stringByAppendingPathComponent:base];
            [fm removeItemAtPath:dest error:nil];
            NSError *exErr = nil;
            BOOL extracted = NO;
            @try {
                extracted = NDExtractArchiveToDirectory(archive, dest, &exErr);
            } @catch (NSException *ex) {
                exErr = [NSError errorWithDomain:@"NDArchive" code:99 userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"解压异常 %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"]
                }];
                extracted = NO;
            }
            if (!extracted) {
                NSString *msg = [NSString stringWithFormat:
                                 @"无法解压 %@\n%@\n建议：用桌面经典包 +1916… 2026-….tar.gz\n"
                                 @"解压后路径必须是 /var/mobile/AMG/<记录名>/\n"
                                 @"或把该文件夹放进 Media/AMG/import 再导入",
                                 entry, exErr.localizedDescription ?: @""];
                [log addObject:msg];
                if (error) {
                    *error = [NSError errorWithDomain:@"NDRecordStore" code:32 userInfo:@{NSLocalizedDescriptionKey: msg}];
                }
                continue;
            }
            [log addObject:[NSString stringWithFormat:@"extracted OK → %@", dest]];

            NSString *importRoot = [[self class] NDUnwrapImportRoot:dest];
            if ([[self class] NDPathLooksLikeAMGRecordDir:importRoot] &&
                ![[self class] NDPathLooksLikeAMGRecordDir:dest]) {
                NSString *parent = [importRoot stringByDeletingLastPathComponent];
                if (parent.length) importRoot = parent;
            }
            // Prefer classic live layout paths first (what AMG recognizes)
            for (NSString *nested in @[@"var/mobile/AMG", @"AMG", @"var/mobile/AMG_tar", @"AMG_tar", @"amg_extract"]) {
                NSString *p = [dest stringByAppendingPathComponent:nested];
                if ([fm fileExistsAtPath:p]) {
                    NSArray *kids = [fm contentsOfDirectoryAtPath:p error:nil] ?: @[];
                    for (NSString *k in kids) {
                        NSString *kp = [p stringByAppendingPathComponent:k];
                        if ([[self class] NDPathLooksLikeClassicAMGRecordDir:kp]
                            || [[self class] NDPathLooksLikeAMGRecordDir:kp]) {
                            importRoot = p;
                            break;
                        }
                    }
                }
            }
            [log addObject:[@"importRoot=" stringByAppendingString:importRoot ?: @""]];
            NSArray *rootKids = [fm contentsOfDirectoryAtPath:importRoot error:nil] ?: @[];
            [log addObject:[NSString stringWithFormat:@"importRootKids=%lu", (unsigned long)rootKids.count]];
            for (NSString *k in rootKids) {
                NSString *kp = [importRoot stringByAppendingPathComponent:k];
                BOOL kd = NO;
                [fm fileExistsAtPath:kp isDirectory:&kd];
                BOOL classic = [[self class] NDPathLooksLikeClassicAMGRecordDir:kp];
                BOOL resolved = [[self class] NDPathLooksLikeResolvedAMGRecordDir:kp];
                [log addObject:[NSString stringWithFormat:@"  kid=%@ dir=%@ classic=%@ resolved=%@",
                                k, kd ? @"YES" : @"NO", classic ? @"YES" : @"NO", resolved ? @"YES" : @"NO"]];
            }
            NSUInteger n = 0;

            // 1) Classic desktop / runtime packs → write /var/mobile/AMG/<记录名>/ + NewDevice
            // Restore AMG record name from archive basename when extract sanitized '+' / spaces.
            NSString *archiveLogical = [[self class] NDArchiveLogicalBaseName:entry];
            for (NSString *k in rootKids) {
                NSString *kp = [importRoot stringByAppendingPathComponent:k];
                BOOL classicKid = [[self class] NDPathLooksLikeClassicAMGRecordDir:kp];
                // Tar extracted flat into dest (dest itself is the record)
                if (!classicKid && [[self class] NDPathLooksLikeClassicAMGRecordDir:importRoot]
                    && [importRoot isEqualToString:kp] == NO) {
                    // only evaluate kids
                }
                if (!classicKid) continue;
                if ([[self class] NDPathLooksLikeResolvedAMGRecordDir:kp]
                    && ![fm fileExistsAtPath:[kp stringByAppendingPathComponent:@"faker.plist"]]) {
                    continue;
                }
                // Prefer original archive name (keeps + and spaces) for /var/mobile/AMG/<记录名>
                NSString *importPath = kp;
                if (archiveLogical.length
                    && ![k isEqualToString:archiveLogical]
                    && ([archiveLogical hasPrefix:@"+"] || [archiveLogical containsString:@" "])) {
                    NSString *renamed = [[importRoot stringByDeletingLastPathComponent] stringByAppendingPathComponent:archiveLogical];
                    // If importRoot IS the record (single flat extract), rename that folder
                    if ([[self class] NDPathLooksLikeClassicAMGRecordDir:importRoot]
                        && rootKids.count <= 2 /* allow faker + apps */) {
                        // handled below via flat case
                    }
                    [fm removeItemAtPath:renamed error:nil];
                    if ([fm moveItemAtPath:kp toPath:renamed error:nil] || [fm copyItemAtPath:kp toPath:renamed error:nil]) {
                        importPath = renamed;
                        [log addObject:[NSString stringWithFormat:@"restoreLiveName %@ → %@", k, archiveLogical]];
                    }
                }
                NSString *note = nil;
                NSError *oneErr = nil;
                BOOL ok = NO;
                @try {
                    ok = [self importClassicAMGRecordAtPath:importPath note:&note error:&oneErr];
                } @catch (NSException *ex) {
                    note = [NSString stringWithFormat:@"exception %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"];
                    ok = NO;
                }
                [log addObject:[NSString stringWithFormat:@"classicLive=%@ ok=%@ note=%@",
                                importPath.lastPathComponent, ok ? @"YES" : @"NO", note ?: (oneErr.localizedDescription ?: @"")]];
                if (ok) n++;
            }
            // Flat extract: importRoot itself is classic (no child record folders)
            if (n == 0 && [[self class] NDPathLooksLikeClassicAMGRecordDir:importRoot]
                && ![[self class] NDPathLooksLikeResolvedAMGRecordDir:importRoot]) {
                NSString *flatPath = importRoot;
                if (archiveLogical.length
                    && ![importRoot.lastPathComponent isEqualToString:archiveLogical]) {
                    NSString *renamed = [[importRoot stringByDeletingLastPathComponent] stringByAppendingPathComponent:archiveLogical];
                    [fm removeItemAtPath:renamed error:nil];
                    if ([fm moveItemAtPath:importRoot toPath:renamed error:nil]
                        || [fm copyItemAtPath:importRoot toPath:renamed error:nil]) {
                        flatPath = renamed;
                        [log addObject:[NSString stringWithFormat:@"restoreFlatLiveName → %@", archiveLogical]];
                    }
                }
                NSString *note = nil;
                NSError *oneErr = nil;
                BOOL ok = NO;
                @try {
                    ok = [self importClassicAMGRecordAtPath:flatPath note:&note error:&oneErr];
                } @catch (NSException *ex) {
                    note = [NSString stringWithFormat:@"exception %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"];
                    ok = NO;
                }
                [log addObject:[NSString stringWithFormat:@"classicFlat=%@ ok=%@ note=%@",
                                flatPath.lastPathComponent, ok ? @"YES" : @"NO", note ?: (oneErr.localizedDescription ?: @"")]];
                if (ok) n++;
            }

            // 2) AMG_resolved analysis packs → NewDevice only (does NOT install into /var/mobile/AMG)
            if (n == 0) {
                for (NSString *k in rootKids) {
                    NSString *kp = [importRoot stringByAppendingPathComponent:k];
                    if (![[self class] NDPathLooksLikeResolvedAMGRecordDir:kp]) continue;
                    NSString *safeName = [[[k stringByReplacingOccurrencesOfString:@"+" withString:@""]
                                           stringByReplacingOccurrencesOfString:@" " withString:@"_"]
                                          stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                    if (!safeName.length) safeName = @"amg-resolved-record";
                    NSString *safePath = [[importRoot stringByDeletingLastPathComponent] stringByAppendingPathComponent:safeName];
                    if (![safePath isEqualToString:kp]) {
                        [fm removeItemAtPath:safePath error:nil];
                        NSError *cpErr = nil;
                        if (![fm copyItemAtPath:kp toPath:safePath error:&cpErr]) {
                            [log addObject:[NSString stringWithFormat:@"safeCopy fail %@ — %@; using original", safeName, cpErr.localizedDescription ?: @"?"]];
                            safePath = kp;
                        } else {
                            [log addObject:[@"safeCopy OK → " stringByAppendingString:safeName]];
                        }
                    }
                    NSString *note = nil;
                    NSError *oneErr = nil;
                    BOOL ok = NO;
                    @try {
                        ok = [self importAMGResolvedRecordAtPath:safePath note:&note error:&oneErr];
                    } @catch (NSException *ex) {
                        note = [NSString stringWithFormat:@"exception %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"];
                        ok = NO;
                    }
                    [log addObject:[NSString stringWithFormat:@"directResolved=%@ ok=%@ note=%@ (analysis-only, not AMG live)",
                                    safePath.lastPathComponent, ok ? @"YES" : @"NO", note ?: (oneErr.localizedDescription ?: @"")]];
                    if (ok) n++;
                }
            }
            if (n == 0) {
                @try {
                    n = [self NDImportUnpackedTree:importRoot importKeychain:importKeychain error:nil];
                } @catch (NSException *ex) {
                    [log addObject:[NSString stringWithFormat:@"archiveImport exception %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"]];
                }
            }
            total += n;
            [log addObject:[NSString stringWithFormat:@"archiveImport=%lu", (unsigned long)n]];
            if (!n) {
                [log addObject:@"HINT: extract OK but no classic/resolved record imported. Prefer desktop +1916….tar.gz → /var/mobile/AMG/<记录名>/"];
            }
        }

        // Keep scratch for Filza debug when import fails; remove when success
        if (total > 0) [fm removeItemAtPath:scratchRoot error:nil];
        else {
            [log addObject:[@"scratchKept=" stringByAppendingString:scratchRoot ?: @""]];
        }
    } @catch (NSException *ex) {
        NSArray *syms = ex.callStackSymbols;
        NSString *stack = [syms isKindOfClass:[NSArray class]] ? [syms componentsJoinedByString:@"\n"] : @"";
        NSString *msg = [NSString stringWithFormat:@"导入异常：%@ — %@\n%@",
                         ex.name ?: @"NSException",
                         ex.reason ?: @"?",
                         stack ?: @""];
        if (msg.length > 1200) msg = [[msg substringToIndex:1200] stringByAppendingString:@"…"];
        [log addObject:msg];
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:99 userInfo:@{NSLocalizedDescriptionKey: msg}];
    }

    [self endImportSession];
    [log addObject:[NSString stringWithFormat:@"total=%lu names=%@", (unsigned long)total,
                    [self.lastImportedRecordNames componentsJoinedByString:@", "] ?: @"(none)"]];
    if (self.lastImportHoloSummary.length) {
        [log addObject:@"--- import notes ---"];
        [log addObject:self.lastImportHoloSummary];
    }
    [[self class] NDWriteImportLog:[log componentsJoinedByString:@"\n"]];

    if (total == 0 && error && !*error) {
        NSString *msg = [NSString stringWithFormat:
                         @"未找到可导入的 AMG 记录。\n当前扫描：%@\n目录内：%@\n\n"
                         @"请用桌面经典包（不是 AMG_resolved 分析包）：\n"
                         @"1) 把 +1916… 2026-….tar.gz 放到 /var/mobile/Media/AMG/import\n"
                         @"2) 或电脑解压后保证路径是 /var/mobile/AMG/<记录名>/\n"
                         @"3) AMG_resolved（01_/02_/03_）只能给 NewDevice 看明文，AMG 不认\n\n详见 nd-last-import.txt",
                         dir,
                         entries.count ? [entries componentsJoinedByString:@", "] : @"(空)"];
        *error = [NSError errorWithDomain:@"NDRecordStore" code:31 userInfo:@{NSLocalizedDescriptionKey: msg}];
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
