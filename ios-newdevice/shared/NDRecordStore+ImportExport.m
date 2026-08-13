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
        NSString *msg = [NSString stringWithFormat:@"AMG 导入目录不存在: %@\n请把 AMG_resolved_*.tar.gz 放到\n/var/mobile/Media/AMG/import", dir];
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
        // 1) Folder trees (incl. amg_extract unwrap)
        {
            NSError *err = nil;
            NSUInteger n = [self NDImportUnpackedTree:dir importKeychain:importKeychain error:&err];
            total += n;
            [log addObject:[NSString stringWithFormat:@"folderImport=%lu", (unsigned long)n]];
            if (error && err) *error = err;
        }

        // 2) Archives (accept mangled .tar_*.gz names from chat/Aisi)
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
                NSString *msg = [NSString stringWithFormat:@"无法解压 %@\n%@\n建议：电脑解压后，把文件夹\namg_extract/+1916…（含 01_plaintext_identity）\n直接放进 /var/mobile/Media/AMG/import/",
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
            for (NSString *nested in @[@"var/mobile/AMG", @"var/mobile/AMG_tar", @"AMG", @"AMG_tar", @"amg_extract"]) {
                NSString *p = [dest stringByAppendingPathComponent:nested];
                if ([fm fileExistsAtPath:p]) {
                    NSArray *kids = [fm contentsOfDirectoryAtPath:p error:nil] ?: @[];
                    for (NSString *k in kids) {
                        if ([[self class] NDPathLooksLikeAMGRecordDir:[p stringByAppendingPathComponent:k]]) {
                            importRoot = p;
                            break;
                        }
                    }
                }
            }
            [log addObject:[@"importRoot=" stringByAppendingString:importRoot ?: @""]];
            // List what extract actually produced (debug archiveImport=0)
            NSArray *rootKids = [fm contentsOfDirectoryAtPath:importRoot error:nil] ?: @[];
            [log addObject:[NSString stringWithFormat:@"importRootKids=%lu", (unsigned long)rootKids.count]];
            for (NSString *k in rootKids) {
                NSString *kp = [importRoot stringByAppendingPathComponent:k];
                BOOL kd = NO;
                [fm fileExistsAtPath:kp isDirectory:&kd];
                BOOL has01 = [fm fileExistsAtPath:[kp stringByAppendingPathComponent:@"01_plaintext_identity"]];
                BOOL hasPlain = [fm fileExistsAtPath:[[kp stringByAppendingPathComponent:@"01_plaintext_identity"] stringByAppendingPathComponent:@"faker_plaintext.plist"]];
                [log addObject:[NSString stringWithFormat:@"  kid=%@ dir=%@ 01=%@ plain=%@",
                                k, kd ? @"YES" : @"NO", has01 ? @"YES" : @"NO", hasPlain ? @"YES" : @"NO"]];
            }
            NSUInteger n = 0;
            @try {
                n = [self NDImportUnpackedTree:importRoot importKeychain:importKeychain error:nil];
            } @catch (NSException *ex) {
                [log addObject:[NSString stringWithFormat:@"archiveImport exception %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"]];
            }
            total += n;
            [log addObject:[NSString stringWithFormat:@"archiveImport=%lu", (unsigned long)n]];
            NSString *holo = self.lastImportHoloSummary;
            // lastImportHoloSummary is only set at endImportSession; capture live notes via result file instead
            if (!n) {
                [log addObject:@"HINT: extract OK but 0 records. Check kid 01=/plain= above. If 01=YES plain=YES, identity import failed — see exception lines."];
            }
            (void)holo;
        }

        // Keep scratch on failure for Filza debug; remove only when something imported
        if (total > 0) [fm removeItemAtPath:scratchRoot error:nil];
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
    [[self class] NDWriteImportLog:[log componentsJoinedByString:@"\n"]];

    if (total == 0 && error && !*error) {
        NSString *msg = [NSString stringWithFormat:
                         @"未找到可导入的 AMG 记录。\n当前扫描：%@\n目录内：%@\n\n请确认：\n1) 文件在 /var/mobile/Media/AMG/import\n2) 用 AMG_resolved_ 明文包\n3) 或电脑解压后放 amg_extract 里那层记录文件夹\n\n详见 nd-last-import.txt",
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
