#import "NDRecordStore.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import "NDRuntimeState.h"
#import "NDAppDataManager.h"
#import "NDAMGParamClient.h"
#import "NDDeviceProfile.h"
#import <notify.h>

@interface NDRecordStore ()
@property (nonatomic, copy, readwrite) NSArray<NSString *> *lastImportedRecordNames;
@property (nonatomic, copy, readwrite) NSString *lastImportHoloSummary;
@property (nonatomic, strong) NSMutableArray<NSString *> *importingNames;
@property (nonatomic, strong) NSMutableArray<NSString *> *importingHoloLines;
@end

@implementation NDRecordStore

+ (instancetype)shared {
    static NDRecordStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [NDRecordStore new];
        [NDPaths ensureDirectories];
        [store ensureOriginalRecord];
    });
    return store;
}

+ (BOOL)isReservedRecordFolderName:(NSString *)name {
    if (!name.length || [name hasPrefix:@"."]) return YES;
    static NSSet *reserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reserved = [NSSet setWithArray:@[
            @"import", @"export",
            @"debs", @"stable", @"apt", @"downloads",
            @"config", @"settings", @"records",
            @"amg", @"amg_tar", @"amg_extract", @"igrimace", @"importdata",
            @"nd-export-stage", @"nd-extract",
            @"01_plaintext_identity", @"02_config_plists", @"03_holographic_backups",
            @"使用说明.txt",
        ]];
    });
    return [reserved containsObject:name.lowercaseString];
}

- (void)purgeAccidentalImportExportRecords {
    // Older builds mistakenly imported Media/.../import|export as records.
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in @[@"import", @"export"]) {
        NSString *profile = [NDPaths profilePathForRecord:name];
        if (![fm fileExistsAtPath:profile]) continue;
        if ([[self currentRecordName] isEqualToString:name]) {
            [self setCurrentRecordName:@"原始机器"];
        }
        [fm removeItemAtPath:[NDPaths recordDir:name] error:nil];
    }
}

- (void)ensureOriginalRecord {
    [self purgeAccidentalImportExportRecords];
    NSString *path = [NDPaths profilePathForRecord:@"原始机器"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NDDeviceProfile *p = [NDDeviceProfile originalProfile];
        [p writeToPath:path error:nil];
    }
    if (![self currentRecordName].length) {
        [self setCurrentRecordName:@"原始机器"];
    }
}

- (NSArray<NSString *> *)allRecordNames {
    [self purgeAccidentalImportExportRecords];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:[NDPaths recordsRoot] error:nil] ?: @[];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *name in contents) {
        if ([[self class] isReservedRecordFolderName:name]) continue;
        NSString *profile = [NDPaths profilePathForRecord:name];
        if ([fm fileExistsAtPath:profile]) {
            [names addObject:name];
        }
    }
    [names sortUsingSelector:@selector(localizedCompare:)];
    // Keep 原始机器 first if present
    NSUInteger idx = [names indexOfObject:@"原始机器"];
    if (idx != NSNotFound && idx != 0) {
        [names removeObjectAtIndex:idx];
        [names insertObject:@"原始机器" atIndex:0];
    }
    return names;
}

- (NSString *)currentRecordName {
    // Prefer on-disk pointer (authoritative when NewDevice App/daemon can write it)
    NSString *name = [NSString stringWithContentsOfFile:[NDPaths currentRecordPointerPath] encoding:NSUTF8StringEncoding error:nil];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length) return name;
    // Sandboxed target apps may only see the world-readable runtime snapshot
    NSDictionary *runtime = [NDRuntimeState dictionary];
    NSString *fromRuntime = runtime[@"currentRecord"];
    if ([fromRuntime isKindOfClass:[NSString class]] && fromRuntime.length) {
        return [fromRuntime stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return @"";
}

- (void)setCurrentRecordName:(NSString *)name {
    [NDPaths ensureDirectories];
    NSString *value = name ?: @"原始机器";
    [value writeToFile:[NDPaths currentRecordPointerPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NDPaths makePathWorldReadable:[NDPaths preferencesDir]];
    [NDPaths makePathWorldReadable:[NDPaths currentRecordPointerPath]];
}

- (NDDeviceProfile *)profileNamed:(NSString *)name {
    return [NDDeviceProfile profileAtPath:[NDPaths profilePathForRecord:name]];
}

- (NDDeviceProfile *)currentProfile {
    NSString *name = [self currentRecordName];
    if (name.length) {
        NDDeviceProfile *disk = [self profileNamed:name];
        if (disk) return disk;
    }
    // Sandboxed fallback
    return [NDRuntimeState profileFromDictionary:[NDRuntimeState dictionary]];
}

- (BOOL)saveProfile:(NDDeviceProfile *)profile error:(NSError **)error {
    if (!profile.name.length) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Empty record name"}];
        return NO;
    }
    BOOL ok = [profile writeToPath:[NDPaths profilePathForRecord:profile.name] error:error];
    // During import session, defer notify — mid-import notify_post on a background
    // queue was aborting AMG_resolved imports (archiveImport=0 with extract OK).
    if (ok && self.importingNames == nil) [self notifyReload];
    return ok;
}

- (BOOL)deleteRecord:(NSString *)name error:(NSError **)error {
    if ([name isEqualToString:@"原始机器"]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Cannot delete original record"}];
        return NO;
    }
    NSString *dir = [NDPaths recordDir:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dir]) {
        if (![fm removeItemAtPath:dir error:error]) return NO;
    }
    if ([[self currentRecordName] isEqualToString:name]) {
        [self setCurrentRecordName:@"原始机器"];
        [self notifyReload];
    }
    return YES;
}

- (BOOL)deleteAllRecordsKeepingCurrent:(BOOL)keepCurrent error:(NSError **)error {
    NSString *current = [self currentRecordName];
    for (NSString *name in [self allRecordNames]) {
        if ([name isEqualToString:@"原始机器"]) continue;
        if (keepCurrent && [name isEqualToString:current]) continue;
        if (![self deleteRecord:name error:error]) return NO;
    }
    return YES;
}

- (BOOL)renameRecord:(NSString *)oldName to:(NSString *)newName error:(NSError **)error {
    if ([oldName isEqualToString:@"原始机器"] || [newName isEqualToString:@"原始机器"]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Cannot rename original"}];
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *oldDir = [NDPaths recordDir:oldName];
    NSString *newDir = [NDPaths recordDir:newName];
    if ([fm fileExistsAtPath:newDir]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Target name exists"}];
        return NO;
    }
    if (![fm moveItemAtPath:oldDir toPath:newDir error:error]) return NO;
    NDDeviceProfile *p = [self profileNamed:newName];
    p.name = newName;
    [p writeToPath:[NDPaths profilePathForRecord:newName] error:nil];
    if ([[self currentRecordName] isEqualToString:oldName]) {
        [self setCurrentRecordName:newName];
    }
    [self notifyReload];
    return YES;
}

- (BOOL)setEnabled:(BOOL)enabled forRecord:(NSString *)name error:(NSError **)error {
    NDDeviceProfile *p = [self profileNamed:name];
    if (!p) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Record not found"}];
        return NO;
    }
    p.enabled = enabled;
    return [self saveProfile:p error:error];
}

- (BOOL)setEnabledForAll:(BOOL)enabled error:(NSError **)error {
    for (NSString *name in [self allRecordNames]) {
        if ([name isEqualToString:@"原始机器"]) continue;
        if (![self setEnabled:enabled forRecord:name error:error]) return NO;
    }
    return YES;
}

- (NSString *)makeRecordName {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd-HH-mm-ss";
    NSString *base = [f stringFromDate:[NSDate date]];
    NSString *name = base;
    NSInteger i = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:[NDPaths recordDir:name]]) {
        name = [NSString stringWithFormat:@"%@-%ld", base, (long)i++];
    }
    return name;
}

- (NDDeviceProfile *)createNewRecordAndActivate:(NSError **)error {
    [[NDConfig shared] reload];
    NDConfig *cfg = [NDConfig shared];
    NSString *model = cfg.preferredModels.count ? cfg.preferredModels[arc4random_uniform((uint32_t)cfg.preferredModels.count)] : nil;
    NSString *sys = cfg.preferredSystems.count ? cfg.preferredSystems[arc4random_uniform((uint32_t)cfg.preferredSystems.count)] : nil;
    NDDeviceProfile *p = [NDDeviceProfile randomProfileWithName:[self makeRecordName] preferredModel:model preferredSystem:sys];

    if (!cfg.randomLocation && !cfg.spoofLocation) {
        NDDeviceProfile *cur = [self currentProfile];
        if (cur) {
            p.Latitude = cur.Latitude;
            p.Longitude = cur.Longitude;
            p.Altitude = cur.Altitude;
        }
    } else if (!cfg.randomLocation) {
        NDDeviceProfile *cur = [self currentProfile];
        if (cur && (cur.Latitude != 0 || cur.Longitude != 0)) {
            p.Latitude = cur.Latitude;
            p.Longitude = cur.Longitude;
            p.Altitude = cur.Altitude;
        }
    }

    if (cfg.smartLocationOffset && cfg.spoofLocation) {
        double offsetLat = ((double)arc4random_uniform(200) - 100) / 100000.0;
        double offsetLon = ((double)arc4random_uniform(200) - 100) / 100000.0;
        p.Latitude += offsetLat;
        p.Longitude += offsetLon;
    }

    if (![self saveProfile:p error:error]) return nil;
    [self setCurrentRecordName:p.name];
    [self notifyReload];
    return p;
}

- (BOOL)switchToOriginal:(NSError **)error {
    return [self switchToRecord:@"原始机器" error:error];
}

- (BOOL)switchToNext:(NSError **)error {
    NSArray *names = [self allRecordNames];
    if (!names.count) return [self switchToOriginal:error];
    NSString *current = [self currentRecordName] ?: @"原始机器";
    NSUInteger idx = [names indexOfObject:current];
    NSUInteger next = (idx == NSNotFound) ? 0 : (idx + 1) % names.count;
    // skip disabled
    for (NSUInteger n = 0; n < names.count; n++) {
        NSUInteger i = (next + n) % names.count;
        NDDeviceProfile *p = [self profileNamed:names[i]];
        if (p.enabled || [names[i] isEqualToString:@"原始机器"]) {
            return [self switchToRecord:names[i] error:error];
        }
    }
    return [self switchToOriginal:error];
}

- (BOOL)switchToPrevious:(NSError **)error {
    NSArray *names = [self allRecordNames];
    if (!names.count) return [self switchToOriginal:error];
    NSString *current = [self currentRecordName] ?: @"原始机器";
    NSUInteger idx = [names indexOfObject:current];
    NSUInteger start = (idx == NSNotFound || idx == 0) ? (names.count - 1) : (idx - 1);
    for (NSUInteger n = 0; n < names.count; n++) {
        NSUInteger i = (start + names.count - n) % names.count;
        NDDeviceProfile *p = [self profileNamed:names[i]];
        if (p.enabled || [names[i] isEqualToString:@"原始机器"]) {
            return [self switchToRecord:names[i] error:error];
        }
    }
    return [self switchToOriginal:error];
}

- (BOOL)switchToFirst:(NSError **)error {
    NSArray *names = [self allRecordNames];
    for (NSString *name in names) {
        if ([name isEqualToString:@"原始机器"]) continue;
        NDDeviceProfile *p = [self profileNamed:name];
        if (p.enabled) return [self switchToRecord:name error:error];
    }
    return [self switchToOriginal:error];
}

- (BOOL)switchToRecord:(NSString *)name error:(NSError **)error {
    if (![self profileNamed:name]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Record not found"}];
        return NO;
    }
    [self setCurrentRecordName:name];
    [self notifyReload];
    return YES;
}

- (NDDeviceProfile *)importProfileAtPath:(NSString *)path preferredName:(NSString *)name error:(NSError **)error {
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![raw isKindOfClass:[NSDictionary class]]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:20 userInfo:@{NSLocalizedDescriptionKey: @"Unable to read profile plist"}];
        return nil;
    }
    if ([NDDeviceProfile dictionaryLooksLikeEncryptedAMGFaker:raw]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:24 userInfo:@{NSLocalizedDescriptionKey: @"AMG faker.plist is encrypted on disk; identity values cannot be imported. Holographic app data can still be imported from the record folder."}];
        return nil;
    }
    if (![NDDeviceProfile dictionaryHasImportableIdentity:raw] && !raw[@"Model"] && !raw[@"ProductType"]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:21 userInfo:@{NSLocalizedDescriptionKey: @"Plist has no identity fields"}];
        return nil;
    }
    NDDeviceProfile *p = [NDDeviceProfile profileFromDictionary:raw];
    if (!p) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:20 userInfo:@{NSLocalizedDescriptionKey: @"Unable to parse profile plist"}];
        return nil;
    }
    if (name.length) p.name = name;
    if (!p.name.length || [p.name isEqualToString:@"unnamed"]) {
        p.name = [[path lastPathComponent] stringByDeletingPathExtension];
    }
    if ([p.name isEqualToString:@"原始机器"] || [[self class] isReservedRecordFolderName:p.name]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:22 userInfo:@{NSLocalizedDescriptionKey: @"Skipped reserved name"}];
        return nil;
    }
    p.name = [self sanitizeRecordName:p.name];
    p.enabled = YES;
    if (![self saveProfile:p error:error]) return nil;
    return p;
}

- (NSString *)uniqueRecordName:(NSString *)preferred {
    NSString *base = preferred.length ? preferred : [[NSDate date] description];
    if ([base isEqualToString:@"原始机器"] || [[self class] isReservedRecordFolderName:base]) {
        base = [base stringByAppendingString:@"-record"];
    }
    if (![self profileNamed:base]) return base;
    NSInteger suffix = 2;
    while ([self profileNamed:[NSString stringWithFormat:@"%@-%ld", base, (long)suffix]]) {
        suffix++;
    }
    return [NSString stringWithFormat:@"%@-%ld", base, (long)suffix];
}

+ (BOOL)NDLooksLikeBundleId:(NSString *)s {
    if (s.length < 3) return NO;
    if ([s hasPrefix:@"."]) return NO;
    if ([s containsString:@"/"]) return NO;
    // com.foo / net.x / xyz.willy.Sileo
    NSArray *parts = [s componentsSeparatedByString:@"."];
    if (parts.count < 2) return NO;
    for (NSString *p in parts) {
        if (!p.length) return NO;
    }
    return YES;
}

+ (NSArray<NSString *> *)parseAppBundleIdsFromValue:(id)raw {
    NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
    void (^add)(NSString *) = ^(NSString *s) {
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([[self class] NDLooksLikeBundleId:s]) [out addObject:s];
    };
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)raw) {
            if ([item isKindOfClass:[NSString class]]) {
                add(item);
            } else if ([item isKindOfClass:[NSDictionary class]]) {
                NSDictionary *d = item;
                for (NSString *k in @[@"bundleId", @"bundleID", @"bid", @"id", @"appId", @"identifier", @"bundle"]) {
                    if ([d[k] isKindOfClass:[NSString class]]) add(d[k]);
                }
            }
        }
    } else if ([raw isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = raw;
        if ([d[@"apps"] isKindOfClass:[NSArray class]] || [d[@"appName"] isKindOfClass:[NSArray class]] || [d[@"bundleIds"] isKindOfClass:[NSArray class]]) {
            for (NSString *k in @[@"apps", @"appName", @"bundleIds", @"SelectApp", @"selectApp"]) {
                NSArray *part = [[self class] parseAppBundleIdsFromValue:d[k]];
                for (NSString *b in part) [out addObject:b];
            }
        }
        // { "com.foo.app": true/1/"1", ... }
        [d enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if (![key isKindOfClass:[NSString class]]) return;
            if (![[self class] NDLooksLikeBundleId:key]) return;
            if ([obj isKindOfClass:[NSNumber class]] && ![((NSNumber *)obj) boolValue]) return;
            if ([obj isKindOfClass:[NSString class]]) {
                NSString *s = (NSString *)obj;
                if ([s isEqualToString:@"0"] || [s.lowercaseString isEqualToString:@"false"]) return;
            }
            add(key);
        }];
    }
    return out.array;
}

+ (NSArray<NSString *> *)discoverAppBundleIdsInDirectory:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    static NSSet *skip;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skip = [NSSet setWithArray:@[
            @"AppGroup", @"Pasteboard", @"Documents", @"Library", @"tmp", @"SystemData",
            @"apps", @"debs", @"import", @"export"
        ]];
    });
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        if ([skip containsObject:entry]) continue;
        if ([[entry pathExtension].lowercaseString isEqualToString:@"plist"]) continue;
        if (![[self class] NDLooksLikeBundleId:entry]) continue;
        BOOL isDir = NO;
        NSString *full = [dir stringByAppendingPathComponent:entry];
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) [out addObject:entry];
    }
    // Nested apps/ from NewDevice exports
    NSString *appsNested = [dir stringByAppendingPathComponent:@"apps"];
    BOOL appsDir = NO;
    if ([fm fileExistsAtPath:appsNested isDirectory:&appsDir] && appsDir) {
        for (NSString *b in [[self class] discoverAppBundleIdsInDirectory:appsNested]) [out addObject:b];
    }
    return out.array;
}

- (NSArray<NSString *> *)appBundleIdsForRecord:(NSString *)name {
    if (!name.length || [name isEqualToString:@"原始机器"]) return @[];
    NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
    NSString *root = [NDPaths recordDir:name];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *side in @[@"selectApp.plist", @"selectapp.plist"]) {
        NSString *p = [root stringByAppendingPathComponent:side];
        if (![fm fileExistsAtPath:p]) continue;
        id raw = [NSArray arrayWithContentsOfFile:p];
        if (!raw) raw = [NSDictionary dictionaryWithContentsOfFile:p];
        for (NSString *b in [[self class] parseAppBundleIdsFromValue:raw]) [out addObject:b];
    }
    NSDictionary *desc = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"description.plist"]];
    for (NSString *b in [[self class] parseAppBundleIdsFromValue:desc[@"appName"]]) [out addObject:b];
    for (NSString *b in [[self class] parseAppBundleIdsFromValue:desc[@"apps"]]) [out addObject:b];
    for (NSString *b in [[self class] discoverAppBundleIdsInDirectory:[root stringByAppendingPathComponent:@"apps"]]) [out addObject:b];
    return out.array;
}

- (void)mergeTargetApps:(NSArray *)apps {
    if (![apps isKindOfClass:[NSArray class]] || !apps.count) return;
    // Reload from disk config (not stale runtime) before merge
    NSDictionary *full = [NSDictionary dictionaryWithContentsOfFile:[NDPaths configPlistPath]];
    NDConfig *cfg = [NDConfig shared];
    if ([full isKindOfClass:[NSDictionary class]] && [full[@"targetApps"] isKindOfClass:[NSArray class]]) {
        NSMutableOrderedSet *disk = [NSMutableOrderedSet orderedSetWithArray:full[@"targetApps"]];
        [disk addObjectsFromArray:cfg.targetApps ?: @[]];
        cfg.targetApps = disk.array;
    }
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:cfg.targetApps ?: @[]];
    for (id item in apps) {
        if ([item isKindOfClass:[NSString class]] && [[self class] NDLooksLikeBundleId:item]) [set addObject:item];
    }
    cfg.targetApps = set.array;
    [cfg save];
}

- (NSString *)sanitizeRecordName:(NSString *)preferred {
    NSString *base = preferred.length ? preferred : [self makeRecordName];
    // Avoid URL query '+' / spaces breaking setRecord; keep readable
    base = [base stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([base hasPrefix:@"+"]) base = [base substringFromIndex:1];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < base.length; i++) {
        unichar c = [base characterAtIndex:i];
        if (c < 32) continue;
        if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|') {
            [out appendString:@"_"];
            continue;
        }
        if (c == ' ' || c == '+') {
            [out appendString:@"-"];
            continue;
        }
        [out appendFormat:@"%C", c];
    }
    while ([out containsString:@"--"]) [out replaceOccurrencesOfString:@"--" withString:@"-" options:0 range:NSMakeRange(0, out.length)];
    if (!out.length) out = [[self makeRecordName] mutableCopy];
    if ([out isEqualToString:@"原始机器"] || [[self class] isReservedRecordFolderName:out]) {
        [out appendString:@"-record"];
    }
    return [self uniqueRecordName:out];
}

/// Force-stage holographic apps (incl. Venmo deep-search) into a NewDevice record.
- (void)stageAMGHolographicIntoRecord:(NSString *)recordName fromDir:(NSString *)srcDir {
    if (!recordName.length || !srcDir.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL prevKC = [NDConfig shared].importKeychainWithData;
    [NDConfig shared].importKeychainWithData = YES;
    @try {
        [[NDAppDataManager shared] importAMGHolographicFromDirectory:srcDir intoRecord:recordName];
        for (NSString *base in @[srcDir]) {
            NSString *nestedApps = [base stringByAppendingPathComponent:@"apps"];
            BOOL nestedDir = NO;
            if ([fm fileExistsAtPath:nestedApps isDirectory:&nestedDir] && nestedDir) {
                [[NDAppDataManager shared] importAMGHolographicFromDirectory:nestedApps intoRecord:recordName];
            }
        }
        NSString *venmoStaged = [NDPaths appsBackupDirForRecord:recordName bundleId:@"net.kortina.labs.Venmo"];
        NSString *venmoDocs = [venmoStaged stringByAppendingPathComponent:@"Documents"];
        BOOL venmoOK = [fm fileExistsAtPath:[venmoDocs stringByAppendingPathComponent:@"akc.plist"]]
            || [fm fileExistsAtPath:[venmoDocs stringByAppendingPathComponent:@"Model.sqlite"]]
            || [fm fileExistsAtPath:[venmoStaged stringByAppendingPathComponent:@"akc.plist"]];
        if (!venmoOK) {
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:srcDir];
            for (NSString *rel in en) {
                if (![rel.lastPathComponent isEqualToString:@"net.kortina.labs.Venmo"]) continue;
                NSString *found = [srcDir stringByAppendingPathComponent:rel];
                BOOL d = NO;
                if (![fm fileExistsAtPath:found isDirectory:&d] || !d) continue;
                [[NDAppDataManager shared] importAMGHolographicFromDirectory:[found stringByDeletingLastPathComponent]
                                                                 intoRecord:recordName];
                [fm createDirectoryAtPath:venmoStaged withIntermediateDirectories:YES attributes:nil error:nil];
                for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
                    NSString *src = [found stringByAppendingPathComponent:sub];
                    if (![fm fileExistsAtPath:src]) continue;
                    NSString *dst = [venmoStaged stringByAppendingPathComponent:sub];
                    [fm removeItemAtPath:dst error:nil];
                    [fm copyItemAtPath:src toPath:dst error:nil];
                }
                for (NSString *kcName in @[@"akc.plist", @"keychain-full.plist"]) {
                    NSString *kcSrc = [found stringByAppendingPathComponent:kcName];
                    if (![fm fileExistsAtPath:kcSrc]) {
                        kcSrc = [[found stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:kcName];
                    }
                    if (![fm fileExistsAtPath:kcSrc]) continue;
                    if ([kcName isEqualToString:@"akc.plist"]) {
                        [fm createDirectoryAtPath:venmoDocs withIntermediateDirectories:YES attributes:nil error:nil];
                        NSString *docsAkc = [venmoDocs stringByAppendingPathComponent:@"akc.plist"];
                        [fm removeItemAtPath:docsAkc error:nil];
                        [fm copyItemAtPath:kcSrc toPath:docsAkc error:nil];
                    }
                    NSString *kcDst = [venmoStaged stringByAppendingPathComponent:kcName];
                    [fm removeItemAtPath:kcDst error:nil];
                    [fm copyItemAtPath:kcSrc toPath:kcDst error:nil];
                }
                break;
            }
        }
    } @catch (__unused NSException *ex) {
    }
    [NDConfig shared].importKeychainWithData = prevKC;
}

- (BOOL)importClassicAMGRecordAtPath:(NSString *)recordPath
                                note:(NSString **)outNote
                               error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (!recordPath.length || ![fm fileExistsAtPath:recordPath isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:50 userInfo:@{NSLocalizedDescriptionKey: @"classic record path missing"}];
        if (outNote) *outNote = @"path missing";
        return NO;
    }

    // Preserve AMG folder name exactly (incl. leading '+' and spaces) — AMG keys on this path.
    NSString *liveName = recordPath.lastPathComponent ?: @"amg-record";
    if ([liveName hasPrefix:@"."] || !liveName.length) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:51 userInfo:@{NSLocalizedDescriptionKey: @"bad classic record name"}];
        if (outNote) *outNote = @"bad name";
        return NO;
    }

    NSString *liveRoot = @"/var/mobile/AMG";
    [fm createDirectoryAtPath:liveRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
    NSString *livePath = [liveRoot stringByAppendingPathComponent:liveName];
    // Skip self-copy when already importing from live AMG tree
    BOOL alreadyLive = [recordPath isEqualToString:livePath] || [recordPath hasPrefix:[liveRoot stringByAppendingString:@"/"]];
    if (!alreadyLive) {
        [fm removeItemAtPath:livePath error:nil];
        NSError *cpErr = nil;
        if (![fm copyItemAtPath:recordPath toPath:livePath error:&cpErr]) {
            if (error) *error = cpErr ?: [NSError errorWithDomain:@"NDRecordStore" code:52 userInfo:@{NSLocalizedDescriptionKey: @"copy to /var/mobile/AMG failed"}];
            if (outNote) *outNote = [NSString stringWithFormat:@"liveInstall fail: %@", cpErr.localizedDescription ?: @"?"];
            return NO;
        }
    }
    // Import source: prefer live path (what AMG sees)
    NSString *src = alreadyLive ? recordPath : livePath;

    if (!self.importingNames) self.importingNames = [NSMutableArray array];
    if (!self.importingHoloLines) self.importingHoloLines = [NSMutableArray array];

    NSString *recordName = [self sanitizeRecordName:liveName];
    NDDeviceProfile *saved = nil;
    NSError *impErr = nil;
    NSString *fakerPath = [src stringByAppendingPathComponent:@"faker.plist"];
    NSString *plainPath = [src stringByAppendingPathComponent:@"faker_plaintext.plist"];
    BOOL fakerEncrypted = NO;
    if ([fm fileExistsAtPath:plainPath]) {
        saved = [self importProfileAtPath:plainPath preferredName:recordName error:&impErr];
    } else if ([fm fileExistsAtPath:fakerPath]) {
        NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:fakerPath];
        fakerEncrypted = [NDDeviceProfile dictionaryLooksLikeEncryptedAMGFaker:raw];
        if (!fakerEncrypted) {
            saved = [self importProfileAtPath:fakerPath preferredName:recordName error:&impErr];
        } else {
            // Official plaintext API / sidecar
            NSString *paramNote = nil;
            NSDictionary *plain = [NDAMGParamClient resolvePlaintextParamForAMGRecordDir:src
                                                                            recordTitle:liveName
                                                                             sourceNote:&paramNote];
            if (plain) {
                NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"nd-classic-plain-%@.plist", recordName]];
                [plain writeToFile:tmp atomically:YES];
                saved = [self importProfileAtPath:tmp preferredName:recordName error:&impErr];
            }
        }
    }
    if (!saved) {
        NDDeviceProfile *fresh = [NDDeviceProfile randomProfileWithName:recordName preferredModel:nil preferredSystem:nil];
        fresh.enabled = YES;
        // Ciphertext classic: don't invent spoof IDs that break Venmo session
        fresh.spoofDeviceIdentity = !fakerEncrypted ? YES : NO;
        if ([self saveProfile:fresh error:&impErr]) saved = fresh;
    }
    if (!saved) {
        if (error) *error = impErr ?: [NSError errorWithDomain:@"NDRecordStore" code:53 userInfo:@{NSLocalizedDescriptionKey: @"classic save failed"}];
        if (outNote) *outNote = [NSString stringWithFormat:@"save fail: %@", impErr.localizedDescription ?: @"?"];
        return NO;
    }
    if (!fakerEncrypted) {
        saved.spoofDeviceIdentity = YES;
        [self saveProfile:saved error:nil];
    }

    // Side metadata
    for (NSString *side in @[@"ifaddrs.plist", @"description.plist", @"selectApp.plist", @"selectapp.plist"]) {
        NSString *s = [src stringByAppendingPathComponent:side];
        if (![fm fileExistsAtPath:s]) continue;
        NSString *dstName = [side.lowercaseString isEqualToString:@"selectapp.plist"] ? @"selectApp.plist" : side;
        NSString *dst = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:dstName];
        [fm removeItemAtPath:dst error:nil];
        [fm copyItemAtPath:s toPath:dst error:nil];
    }

    [self stageAMGHolographicIntoRecord:saved.name fromDir:src];

    NSMutableOrderedSet *apps = [NSMutableOrderedSet orderedSet];
    for (NSString *b in [[self class] discoverAppBundleIdsInDirectory:src]) [apps addObject:b];
    id sel = [NSArray arrayWithContentsOfFile:[src stringByAppendingPathComponent:@"selectApp.plist"]];
    if (!sel) sel = [NSDictionary dictionaryWithContentsOfFile:[src stringByAppendingPathComponent:@"selectApp.plist"]];
    for (NSString *b in [[self class] parseAppBundleIdsFromValue:sel]) [apps addObject:b];
    [apps addObject:@"net.kortina.labs.Venmo"];
    if (apps.count) {
        [apps.array writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"selectApp.plist"] atomically:YES];
        [self mergeTargetApps:apps.array];
    }

    NSString *venmoStaged = [NDPaths appsBackupDirForRecord:saved.name bundleId:@"net.kortina.labs.Venmo"];
    NSString *venmoDocs = [venmoStaged stringByAppendingPathComponent:@"Documents"];
    NSString *appsRoot = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"apps"];
    NSArray *staged = [fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
    unsigned long long venmoKB = 0;
    NSDirectoryEnumerator *ven = [fm enumeratorAtPath:venmoStaged];
    for (__unused NSString *r in ven) {
        NSDictionary *attrs = ven.fileAttributes;
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) venmoKB += [attrs fileSize];
    }
    venmoKB /= 1024;
    BOOL akc = [fm fileExistsAtPath:[venmoDocs stringByAppendingPathComponent:@"akc.plist"]]
        || [fm fileExistsAtPath:[venmoStaged stringByAppendingPathComponent:@"akc.plist"]];

    NSString *note = [NSString stringWithFormat:
                      @"Classic AMG write-back.\n"
                      @"liveAMG=%@\n"
                      @"recordsRoot=%@\nrecord=%@\n"
                      @"stagedApps=%@\nvenmoKB=%llu akc=%@\n"
                      @"fakerEncrypted=%@ spoof=%@\n"
                      @"NOTE: AMG only recognizes /var/mobile/AMG/<记录名>/ — not AMG_resolved analysis layout.\n",
                      livePath, [NDPaths recordsRoot], saved.name,
                      [staged componentsJoinedByString:@","],
                      venmoKB, akc ? @"YES" : @"NO",
                      fakerEncrypted ? @"YES" : @"NO",
                      saved.spoofDeviceIdentity ? @"YES" : @"NO"];
    [note writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [note writeToFile:@"/var/mobile/Media/AMG/import/nd-import-status.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (![self.importingNames containsObject:saved.name]) [self.importingNames addObject:saved.name];
    [self.importingHoloLines addObject:[NSString stringWithFormat:@"classic %@ → live=%@ apps=%lu venmoKB=%llu akc=%@",
                                        saved.name, liveName, (unsigned long)staged.count, venmoKB, akc ? @"YES" : @"NO"]];
    if (outNote) {
        *outNote = [NSString stringWithFormat:@"OK classic→/var/mobile/AMG/%@ venmoKB=%llu akc=%@",
                    liveName, venmoKB, akc ? @"YES" : @"NO"];
    }
    return YES;
}

- (BOOL)importAMGResolvedRecordAtPath:(NSString *)recordPath
                                 note:(NSString **)outNote
                                error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (!recordPath.length || ![fm fileExistsAtPath:recordPath isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:40 userInfo:@{NSLocalizedDescriptionKey: @"resolved record path missing"}];
        if (outNote) *outNote = @"path missing";
        return NO;
    }
    NSString *idDir = [recordPath stringByAppendingPathComponent:@"01_plaintext_identity"];
    NSString *cfgDir = [recordPath stringByAppendingPathComponent:@"02_config_plists"];
    NSString *holoDir = [recordPath stringByAppendingPathComponent:@"03_holographic_backups"];
    NSString *plain = [idDir stringByAppendingPathComponent:@"faker_plaintext.plist"];
    if (![fm fileExistsAtPath:plain]) {
        plain = [idDir stringByAppendingPathComponent:@"faker_plaintext.json"];
    }
    if (![fm fileExistsAtPath:plain] && ![fm fileExistsAtPath:holoDir]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:41 userInfo:@{NSLocalizedDescriptionKey: @"no faker_plaintext / holo"}];
        if (outNote) *outNote = @"no plaintext/holo";
        return NO;
    }

    if (!self.importingNames) self.importingNames = [NSMutableArray array];
    if (!self.importingHoloLines) self.importingHoloLines = [NSMutableArray array];

    NSString *folder = recordPath.lastPathComponent ?: @"amg-record";
    NSString *recordName = folder;
    NSDictionary *desc = [NSDictionary dictionaryWithContentsOfFile:[cfgDir stringByAppendingPathComponent:@"description.plist"]];
    if (![desc isKindOfClass:[NSDictionary class]]) {
        desc = [NSDictionary dictionaryWithContentsOfFile:[recordPath stringByAppendingPathComponent:@"description.plist"]];
    }
    if ([desc isKindOfClass:[NSDictionary class]] && [desc[@"title"] isKindOfClass:[NSString class]] && [desc[@"title"] length]) {
        recordName = desc[@"title"];
    }
    recordName = [self sanitizeRecordName:recordName];

    NDDeviceProfile *saved = nil;
    NSError *impErr = nil;
    if ([fm fileExistsAtPath:plain]) {
        NSString *importPath = plain;
        if ([plain.pathExtension.lowercaseString isEqualToString:@"json"]) {
            NSDictionary *raw = [NDAMGParamClient dictionaryAtPath:plain];
            if (raw) {
                importPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"nd-resolved-%@.plist", recordName]];
                [raw writeToFile:importPath atomically:YES];
            }
        }
        saved = [self importProfileAtPath:importPath preferredName:recordName error:&impErr];
    }
    if (!saved) {
        NDDeviceProfile *fresh = [NDDeviceProfile randomProfileWithName:recordName preferredModel:nil preferredSystem:nil];
        fresh.enabled = YES;
        fresh.spoofDeviceIdentity = NO;
        if ([self saveProfile:fresh error:&impErr]) saved = fresh;
    }
    if (!saved) {
        if (error) *error = impErr ?: [NSError errorWithDomain:@"NDRecordStore" code:42 userInfo:@{NSLocalizedDescriptionKey: @"save profile failed"}];
        if (outNote) *outNote = [NSString stringWithFormat:@"save fail: %@", impErr.localizedDescription ?: @"?"];
        return NO;
    }
    saved.spoofDeviceIdentity = YES;
    [self saveProfile:saved error:nil];

    // Config side files
    if ([fm fileExistsAtPath:cfgDir]) {
        for (NSString *cfgName in @[@"selectApp.plist", @"description.plist", @"ifaddrs.plist"]) {
            NSString *src = [cfgDir stringByAppendingPathComponent:cfgName];
            if (![fm fileExistsAtPath:src]) continue;
            NSString *dst = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:cfgName];
            [fm removeItemAtPath:dst error:nil];
            [fm copyItemAtPath:src toPath:dst error:nil];
        }
    }

    // Holo root
    NSString *holoSrc = recordPath;
    if ([fm fileExistsAtPath:holoDir]) {
        NSArray *holoKids = [fm contentsOfDirectoryAtPath:holoDir error:nil] ?: @[];
        if (holoKids.count == 1) {
            NSString *only = [holoDir stringByAppendingPathComponent:holoKids.firstObject];
            BOOL d = NO;
            if ([fm fileExistsAtPath:only isDirectory:&d] && d) holoSrc = only;
            else holoSrc = holoDir;
        } else {
            holoSrc = holoDir;
        }
    }
    // Resolved packs always carry akc — force keychain staging on for this import
    BOOL prevKC = [NDConfig shared].importKeychainWithData;
    [NDConfig shared].importKeychainWithData = YES;
    @try {
        [[NDAppDataManager shared] importAMGHolographicFromDirectory:holoSrc intoRecord:saved.name];
        // Classic nested apps/ (sibling of AppGroup)
        for (NSString *base in @[holoSrc, holoDir, recordPath]) {
            if (!base.length || ![fm fileExistsAtPath:base]) continue;
            NSString *nestedApps = [base stringByAppendingPathComponent:@"apps"];
            BOOL nestedDir = NO;
            if ([fm fileExistsAtPath:nestedApps isDirectory:&nestedDir] && nestedDir) {
                [[NDAppDataManager shared] importAMGHolographicFromDirectory:nestedApps intoRecord:saved.name];
            }
        }
        // Fallback: deep-search Venmo and stage parent + direct Documents/Library copy
        NSString *venmoStaged = [NDPaths appsBackupDirForRecord:saved.name bundleId:@"net.kortina.labs.Venmo"];
        NSString *venmoDocs = [venmoStaged stringByAppendingPathComponent:@"Documents"];
        BOOL venmoOK = [fm fileExistsAtPath:[venmoDocs stringByAppendingPathComponent:@"akc.plist"]]
            || [fm fileExistsAtPath:[venmoDocs stringByAppendingPathComponent:@"Model.sqlite"]]
            || [fm fileExistsAtPath:[venmoStaged stringByAppendingPathComponent:@"akc.plist"]];
        if (!venmoOK) {
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:recordPath];
            for (NSString *rel in en) {
                if (![rel.lastPathComponent isEqualToString:@"net.kortina.labs.Venmo"]) continue;
                NSString *found = [recordPath stringByAppendingPathComponent:rel];
                BOOL d = NO;
                if (![fm fileExistsAtPath:found isDirectory:&d] || !d) continue;
                [[NDAppDataManager shared] importAMGHolographicFromDirectory:[found stringByDeletingLastPathComponent]
                                                                 intoRecord:saved.name];
                // Direct copy if holographic importer still missed (odd layouts)
                [fm createDirectoryAtPath:venmoStaged withIntermediateDirectories:YES attributes:nil error:nil];
                for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
                    NSString *src = [found stringByAppendingPathComponent:sub];
                    if (![fm fileExistsAtPath:src]) continue;
                    NSString *dst = [venmoStaged stringByAppendingPathComponent:sub];
                    [fm removeItemAtPath:dst error:nil];
                    [fm copyItemAtPath:src toPath:dst error:nil];
                }
                for (NSString *kcName in @[@"akc.plist", @"keychain-full.plist"]) {
                    NSString *kcSrc = [found stringByAppendingPathComponent:kcName];
                    if (![fm fileExistsAtPath:kcSrc]) {
                        kcSrc = [[found stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:kcName];
                    }
                    if (![fm fileExistsAtPath:kcSrc]) continue;
                    NSString *kcDst = [venmoStaged stringByAppendingPathComponent:kcName];
                    if ([kcName isEqualToString:@"akc.plist"]) {
                        // Prefer Documents/akc.plist layout used by restore
                        NSString *docsAkc = [venmoDocs stringByAppendingPathComponent:@"akc.plist"];
                        [fm createDirectoryAtPath:venmoDocs withIntermediateDirectories:YES attributes:nil error:nil];
                        [fm removeItemAtPath:docsAkc error:nil];
                        [fm copyItemAtPath:kcSrc toPath:docsAkc error:nil];
                    }
                    [fm removeItemAtPath:kcDst error:nil];
                    [fm copyItemAtPath:kcSrc toPath:kcDst error:nil];
                }
                break;
            }
        }
    } @catch (NSException *ex) {
        NSString *note = [NSString stringWithFormat:@"holo stage exception: %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"];
        [self.importingHoloLines addObject:note];
        NSString *logPath = @"/var/mobile/Media/AMG/import/nd-last-import.txt";
        NSString *prev = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [[prev stringByAppendingFormat:@"\n%@\n", note] writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [NDConfig shared].importKeychainWithData = prevKC;

    NSString *venmoStaged = [NDPaths appsBackupDirForRecord:saved.name bundleId:@"net.kortina.labs.Venmo"];
    NSString *venmoDocs = [venmoStaged stringByAppendingPathComponent:@"Documents"];

    NSMutableOrderedSet *apps = [NSMutableOrderedSet orderedSet];
    for (NSString *b in [[self class] discoverAppBundleIdsInDirectory:holoSrc]) [apps addObject:b];
    id sel = [NSArray arrayWithContentsOfFile:[cfgDir stringByAppendingPathComponent:@"selectApp.plist"]];
    if (!sel) sel = [NSDictionary dictionaryWithContentsOfFile:[cfgDir stringByAppendingPathComponent:@"selectApp.plist"]];
    for (NSString *b in [[self class] parseAppBundleIdsFromValue:sel]) [apps addObject:b];
    [apps addObject:@"net.kortina.labs.Venmo"];
    if (apps.count) {
        [apps.array writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"selectApp.plist"] atomically:YES];
        NDConfig *cfg = [NDConfig shared];
        NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:cfg.targetApps ?: @[]];
        for (NSString *b in apps.array) {
            if ([[self class] NDLooksLikeBundleId:b]) [set addObject:b];
        }
        cfg.targetApps = set.array;
        NSMutableDictionary *disk = [[NSDictionary dictionaryWithContentsOfFile:[NDPaths configPlistPath]] mutableCopy] ?: [NSMutableDictionary dictionary];
        disk[@"targetApps"] = cfg.targetApps ?: @[];
        [disk writeToFile:[NDPaths configPlistPath] atomically:YES];
    }

    [saved writeAMGFakerToDirectory:[NDPaths recordDir:saved.name] error:nil];

    NSString *appsRoot = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"apps"];
    NSArray *staged = [fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
    unsigned long long venmoKB = 0;
    NSDirectoryEnumerator *ven = [fm enumeratorAtPath:venmoStaged];
    for (__unused NSString *r in ven) {
        NSDictionary *attrs = ven.fileAttributes;
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) venmoKB += [attrs fileSize];
    }
    venmoKB /= 1024;
    BOOL akc = [fm fileExistsAtPath:[venmoDocs stringByAppendingPathComponent:@"akc.plist"]]
        || [fm fileExistsAtPath:[venmoStaged stringByAppendingPathComponent:@"akc.plist"]]
        || [fm fileExistsAtPath:[venmoStaged stringByAppendingPathComponent:@"keychain-full.plist"]];

    NSString *note = [NSString stringWithFormat:
                      @"Identity from faker_plaintext (AMG_resolved direct).\n"
                      @"recordsRoot=%@\nrecord=%@\nholoSrc=%@\nstagedApps=%@\nvenmoKB=%llu akc=%@\n",
                      [NDPaths recordsRoot], saved.name, holoSrc,
                      [staged componentsJoinedByString:@","],
                      venmoKB, akc ? @"YES" : @"NO"];
    [note writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // Also drop a copy where Aisi can see it
    [note writeToFile:@"/var/mobile/Media/AMG/import/nd-import-status.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (![self.importingNames containsObject:saved.name]) [self.importingNames addObject:saved.name];
    [self.importingHoloLines addObject:[NSString stringWithFormat:@"%@ → apps=%lu venmoKB=%llu akc=%@",
                                        saved.name, (unsigned long)staged.count, venmoKB, akc ? @"YES" : @"NO"]];
    if (outNote) {
        *outNote = [NSString stringWithFormat:@"OK %@ venmoKB=%llu akc=%@", saved.name, venmoKB, akc ? @"YES" : @"NO"];
    }
    return YES;
}

- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir error:(NSError **)error {
    if (!dir.length) dir = @"/var/mobile/AMG_tar";
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:23 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AMG directory not found: %@", dir]}];
        return 0;
    }

    BOOL nestedInSession = (self.importingNames != nil);
    if (!nestedInSession) {
        self.importingNames = [NSMutableArray array];
        self.importingHoloLines = [NSMutableArray array];
    }

    static NSSet *metaPlists;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        metaPlists = [NSSet setWithArray:@[
            @"description.plist", @"selectapp.plist", @"ifaddrs.plist", @"info.plist",
            @"config.plist", @"settings.plist"
        ]];
    });

    NSUInteger imported = 0;
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    // Build work list: top-level entries + children under wrappers (amg_extract / AMG)
    NSMutableArray<NSString *> *workEntries = [NSMutableArray array];
    NSMutableArray<NSString *> *workFulls = [NSMutableArray array];
    void (^addWork)(NSString *, NSString *) = ^(NSString *name, NSString *full) {
        if (!name.length || !full.length) return;
        if ([workFulls containsObject:full]) return;
        [workEntries addObject:name];
        [workFulls addObject:full];
    };
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:entry];
        BOOL entryIsDir = NO;
        [fm fileExistsAtPath:full isDirectory:&entryIsDir];
        if (!entryIsDir) {
            addWork(entry, full);
            continue;
        }
        // Wrapper dirs are reserved — descend one level to real records
        NSString *lower = entry.lowercaseString;
        BOOL wrapper = [lower isEqualToString:@"amg_extract"] || [lower isEqualToString:@"amg"] || [lower isEqualToString:@"amg_tar"];
        BOOL resolvedHere = [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"01_plaintext_identity"]]
            || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"03_holographic_backups"]]
            || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"faker.plist"]]
            || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"faker_plaintext.plist"]];
        if (wrapper && !resolvedHere) {
            NSArray *kids = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
            for (NSString *k in kids) {
                if ([k hasPrefix:@"."]) continue;
                if ([[self class] isReservedRecordFolderName:k]) continue;
                addWork(k, [full stringByAppendingPathComponent:k]);
            }
            continue;
        }
        if ([[self class] isReservedRecordFolderName:entry] && !resolvedHere) continue;
        addWork(entry, full);
    }

    for (NSUInteger wi = 0; wi < workEntries.count; wi++) {
        NSString *entry = workEntries[wi];
        NSString *full = workFulls[wi];
        BOOL entryIsDir = NO;
        [fm fileExistsAtPath:full isDirectory:&entryIsDir];

        if (!entryIsDir) {
            if (![[entry pathExtension].lowercaseString isEqualToString:@"plist"]) continue;
            if ([metaPlists containsObject:entry.lowercaseString]) continue;
            if ([[self class] isReservedRecordFolderName:[entry stringByDeletingPathExtension]]) continue;
            @try {
                if ([self importProfileAtPath:full preferredName:[entry stringByDeletingPathExtension] error:nil]) {
                    imported++;
                }
            } @catch (__unused NSException *ex) {}
            continue;
        }

        // Resolved extract layout: 01_plaintext_identity / 02_config_plists / 03_holographic_backups
        NSString *idDir = [full stringByAppendingPathComponent:@"01_plaintext_identity"];
        NSString *cfgDir = [full stringByAppendingPathComponent:@"02_config_plists"];
        NSString *holoDir = [full stringByAppendingPathComponent:@"03_holographic_backups"];
        BOOL resolvedLayout = [fm fileExistsAtPath:idDir] || [fm fileExistsAtPath:cfgDir] || [fm fileExistsAtPath:holoDir];

        NSString *recordName = entry;
        NSDictionary *desc = [NSDictionary dictionaryWithContentsOfFile:[full stringByAppendingPathComponent:@"description.plist"]];
        if (![desc isKindOfClass:[NSDictionary class]] && resolvedLayout) {
            desc = [NSDictionary dictionaryWithContentsOfFile:[cfgDir stringByAppendingPathComponent:@"description.plist"]];
        }
        if ([desc isKindOfClass:[NSDictionary class]] && [desc[@"title"] isKindOfClass:[NSString class]] && [desc[@"title"] length]) {
            recordName = desc[@"title"];
        }
        if ([[self class] isReservedRecordFolderName:recordName]) {
            recordName = entry;
            if ([[self class] isReservedRecordFolderName:recordName]) continue;
        }
        recordName = [self sanitizeRecordName:recordName];
        @try {
        // Holographic source: nested 03/.../<record> or classic AMG folder itself
        NSString *holoSrc = full;
        if ([fm fileExistsAtPath:holoDir]) {
            NSArray *holoKids = [fm contentsOfDirectoryAtPath:holoDir error:nil] ?: @[];
            if (holoKids.count == 1) {
                NSString *only = [holoDir stringByAppendingPathComponent:holoKids.firstObject];
                BOOL d = NO;
                if ([fm fileExistsAtPath:only isDirectory:&d] && d) holoSrc = only;
                else holoSrc = holoDir;
            } else {
                holoSrc = holoDir;
            }
        }
        // Merge config plists into a working view: copy missing markers from 02_ into full if needed
        if ([fm fileExistsAtPath:cfgDir]) {
            for (NSString *cfgName in @[@"selectApp.plist", @"description.plist", @"ifaddrs.plist"]) {
                NSString *dst = [full stringByAppendingPathComponent:cfgName];
                NSString *src = [cfgDir stringByAppendingPathComponent:cfgName];
                if (![fm fileExistsAtPath:dst] && [fm fileExistsAtPath:src]) {
                    [fm copyItemAtPath:src toPath:dst error:nil];
                }
            }
            NSString *pbSrc = [cfgDir stringByAppendingPathComponent:@"Pasteboard"];
            NSString *pbDst = [full stringByAppendingPathComponent:@"Pasteboard"];
            if (![fm fileExistsAtPath:pbDst] && [fm fileExistsAtPath:pbSrc]) {
                [fm copyItemAtPath:pbSrc toPath:pbDst error:nil];
            }
        }

        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        // Prefer official plaintext sidecars (getRecordParam / resolved 01_plaintext_identity)
        // Build nested paths component-wise — some iOS versions mishandle "/" inside appendingPathComponent.
        for (NSString *rel in [NDAMGParamClient sidecarPlaintextRelativePaths]) {
            NSString *p = full;
            for (NSString *comp in [rel componentsSeparatedByString:@"/"]) {
                if (!comp.length) continue;
                p = [p stringByAppendingPathComponent:comp];
            }
            if ([fm fileExistsAtPath:p]) [candidates addObject:p];
        }
        // Explicit resolved-layout fallbacks
        for (NSString *name in @[@"faker_plaintext.plist", @"faker_plaintext.json", @"param.plist"]) {
            NSString *p = [idDir stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:p] && ![candidates containsObject:p]) [candidates insertObject:p atIndex:0];
        }
        NSString *faker = [full stringByAppendingPathComponent:@"faker.plist"];
        if ([fm fileExistsAtPath:faker]) [candidates addObject:faker];
        NSString *cipherArchive = [idDir stringByAppendingPathComponent:@"faker.plist.ciphertext"];
        (void)cipherArchive; // keep ciphertext for archive only; never import as identity
        NSString *profile = [full stringByAppendingPathComponent:@"profile.plist"];
        if ([fm fileExistsAtPath:profile]) [candidates addObject:profile];
        NSArray *inner = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
        for (NSString *f in inner) {
            if (![[f pathExtension].lowercaseString isEqualToString:@"plist"] &&
                ![[f pathExtension].lowercaseString isEqualToString:@"json"]) continue;
            if ([metaPlists containsObject:f.lowercaseString]) continue;
            if ([f.lowercaseString isEqualToString:@"faker.plist"] || [f.lowercaseString isEqualToString:@"profile.plist"]) continue;
            if ([[NDAMGParamClient sidecarPlaintextFileNames] containsObject:f]) continue;
            NSString *p = [full stringByAppendingPathComponent:f];
            if (![candidates containsObject:p]) [candidates addObject:p];
        }

        // App env markers: selectApp / AppGroup / bundle-id folders (classic or 03_holographic)
        NSArray *discoveredApps = [[self class] discoverAppBundleIdsInDirectory:holoSrc];
        if (!discoveredApps.count && resolvedLayout) {
            discoveredApps = [[self class] discoverAppBundleIdsInDirectory:full];
        }
        BOOL hasHolo = discoveredApps.count > 0
            || [fm fileExistsAtPath:[holoSrc stringByAppendingPathComponent:@"AppGroup"]]
            || [fm fileExistsAtPath:[holoSrc stringByAppendingPathComponent:@"Pasteboard"]]
            || [fm fileExistsAtPath:[holoSrc stringByAppendingPathComponent:@"apps"]]
            || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"selectApp.plist"]]
            || [fm fileExistsAtPath:[cfgDir stringByAppendingPathComponent:@"selectApp.plist"]];

        NDDeviceProfile *saved = nil;
        BOOL fakerEncrypted = NO;
        NSString *fakerPathProbe = [full stringByAppendingPathComponent:@"faker.plist"];
        if ([fm fileExistsAtPath:fakerPathProbe]) {
            NSDictionary *fakerRawProbe = [NSDictionary dictionaryWithContentsOfFile:fakerPathProbe];
            fakerEncrypted = [NDDeviceProfile dictionaryLooksLikeEncryptedAMGFaker:fakerRawProbe];
        }

        // Runtime ciphertext: resolve plaintext via sidecar or AMG getRecordParam API (no AES RE)
        NSString *paramSourceNote = nil;
        BOOL resolvedPlaintext = NO;
        if (fakerEncrypted) {
            NSString *amgTitle = nil;
            if ([desc[@"title"] isKindOfClass:[NSString class]]) amgTitle = desc[@"title"];
            if (!amgTitle.length) amgTitle = entry;
            NSDictionary *plain = [NDAMGParamClient resolvePlaintextParamForAMGRecordDir:full
                                                                            recordTitle:amgTitle
                                                                             sourceNote:&paramSourceNote];
            if (plain) {
                NSString *plainPath = [full stringByAppendingPathComponent:@"faker_plaintext.plist"];
                [plain writeToFile:plainPath atomically:YES];
                [candidates insertObject:plainPath atIndex:0];
                resolvedPlaintext = YES;
                fakerEncrypted = NO;
            }
        }

        if (self.importingHoloLines) {
            [self.importingHoloLines addObject:[NSString stringWithFormat:@"try %@ resolved=%@ candidates=%lu hasHolo=%@ apps=%lu",
                                               entry, resolvedLayout ? @"YES" : @"NO",
                                               (unsigned long)candidates.count,
                                               hasHolo ? @"YES" : @"NO",
                                               (unsigned long)discoveredApps.count]];
        }
        for (NSString *plistPath in candidates) {
            NSDictionary *raw = [NDAMGParamClient dictionaryAtPath:plistPath];
            if (!raw) raw = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (!raw) {
                if (self.importingHoloLines) {
                    [self.importingHoloLines addObject:[NSString stringWithFormat:@"  skip unreadable %@", plistPath.lastPathComponent]];
                }
                continue;
            }
            if ([NDDeviceProfile dictionaryLooksLikeEncryptedAMGFaker:raw]) {
                if (!resolvedPlaintext) fakerEncrypted = YES;
                if (self.importingHoloLines) {
                    [self.importingHoloLines addObject:[NSString stringWithFormat:@"  skip ciphertext %@", plistPath.lastPathComponent]];
                }
                continue;
            }
            // JSON sidecars: write a temp plist for importProfileAtPath
            NSString *importPath = plistPath;
            if ([plistPath.pathExtension.lowercaseString isEqualToString:@"json"] && raw) {
                importPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"nd-plain-%@.plist", recordName]];
                [raw writeToFile:importPath atomically:YES];
            }
            NSError *impErr = nil;
            saved = [self importProfileAtPath:importPath preferredName:recordName error:&impErr];
            if (saved) {
                saved.spoofDeviceIdentity = YES;
                [self saveProfile:saved error:nil];
                if (paramSourceNote.length || resolvedLayout) {
                    NSString *note = [NSString stringWithFormat:@"Identity from %@%@.",
                                      paramSourceNote.length ? paramSourceNote : plistPath.lastPathComponent,
                                      resolvedLayout ? @" (AMG_resolved layout)" : @" (AMG plaintext API/sidecar)"];
                    [note writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"]
                          atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
                break;
            }
            if (self.importingHoloLines) {
                [self.importingHoloLines addObject:[NSString stringWithFormat:@"  importProfile fail %@ — %@",
                                                   plistPath.lastPathComponent, impErr.localizedDescription ?: @"?"]];
            }
        }

        // Do NOT invent a record for empty container folders (this created bogus "import"/"export").
        if (!saved) {
            if (!hasHolo && !fakerEncrypted) {
                if (self.importingHoloLines) {
                    [self.importingHoloLines addObject:[NSString stringWithFormat:@"skip %@: no identity + no holo", entry]];
                }
                continue;
            }
            if (!hasHolo) {
                if (self.importingHoloLines) {
                    [self.importingHoloLines addObject:[NSString stringWithFormat:@"skip %@: ciphertext/no-holo", entry]];
                }
                continue;
            }
            NDDeviceProfile *fresh = [NDDeviceProfile randomProfileWithName:recordName preferredModel:nil preferredSystem:nil];
            fresh.enabled = YES;
            // Ciphertext faker: do NOT spoof random IDFA/UDID — that breaks Venmo session
            // even when akc Keychain restore succeeds. Passthrough real device identity.
            if (fakerEncrypted) {
                fresh.spoofDeviceIdentity = NO;
            }
            // Best-effort: seed Wi‑Fi MAC from ifaddrs.plist when faker is ciphertext
            NSDictionary *ifa = [NSDictionary dictionaryWithContentsOfFile:[full stringByAppendingPathComponent:@"ifaddrs.plist"]];
            NSDictionary *en0 = [ifa[@"en0"] isKindOfClass:[NSDictionary class]] ? ifa[@"en0"] : nil;
            NSString *mac = [en0[@"mac"] isKindOfClass:[NSString class]] ? en0[@"mac"] : nil;
            if (mac.length && ![mac isEqualToString:@"02:00:00:00:00:00"]) {
                fresh.WiFiMAC = mac;
            }
            if ([self saveProfile:fresh error:nil]) {
                saved = fresh;
                NSString *note = fakerEncrypted
                    ? [NSString stringWithFormat:@"faker.plist is AMG at-rest ciphertext; no plaintext from getRecordParam/sidecar (%@). App data + akc imported; device spoof DISABLED. Put Get_Param output as faker_plaintext.plist and re-import.", paramSourceNote ?: @"-"]
                    : @"No plaintext AMG identity plist found; generated a new random identity. App holographic data was imported when present.";
                [note writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"]
                      atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        if (!saved) continue;
        // Always enable imported records so they can be selected
        if (!saved.enabled) {
            saved.enabled = YES;
            [self saveProfile:saved error:nil];
        }

        imported++;

        // Collect App environment (selectApp + description + folder names)
        NSMutableOrderedSet *toMerge = [NSMutableOrderedSet orderedSet];
        for (NSString *side in @[@"selectApp.plist", @"selectapp.plist"]) {
            NSString *p = [full stringByAppendingPathComponent:side];
            id raw = [NSArray arrayWithContentsOfFile:p];
            if (!raw) raw = [NSDictionary dictionaryWithContentsOfFile:p];
            for (NSString *b in [[self class] parseAppBundleIdsFromValue:raw]) [toMerge addObject:b];
        }
        NSDictionary *descDict = [NSDictionary dictionaryWithContentsOfFile:[full stringByAppendingPathComponent:@"description.plist"]];
        for (NSString *b in [[self class] parseAppBundleIdsFromValue:descDict[@"appName"]]) [toMerge addObject:b];
        for (NSString *b in [[self class] parseAppBundleIdsFromValue:descDict[@"apps"]]) [toMerge addObject:b];
        for (NSString *b in discoveredApps) [toMerge addObject:b];

        // Side-copy metadata; skip ciphertext faker (identity already saved as profile.plist)
        for (NSString *side in @[@"ifaddrs.plist", @"description.plist", @"selectApp.plist", @"selectapp.plist"]) {
            NSString *src = [full stringByAppendingPathComponent:side];
            if (![fm fileExistsAtPath:src]) continue;
            NSString *dstName = [side.lowercaseString isEqualToString:@"selectapp.plist"] ? @"selectApp.plist" : side;
            NSString *dst = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:dstName];
            [fm removeItemAtPath:dst error:nil];
            [fm copyItemAtPath:src toPath:dst error:nil];
        }
        NSString *fakerSrc = [full stringByAppendingPathComponent:@"faker.plist"];
        if ([fm fileExistsAtPath:fakerSrc]) {
            NSDictionary *fakerRaw = [NSDictionary dictionaryWithContentsOfFile:fakerSrc];
            if (![NDDeviceProfile dictionaryLooksLikeEncryptedAMGFaker:fakerRaw]) {
                NSString *dst = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"faker.plist"];
                [fm removeItemAtPath:dst error:nil];
                [fm copyItemAtPath:fakerSrc toPath:dst error:nil];
            }
        }
        NSString *pbSrc = [full stringByAppendingPathComponent:@"Pasteboard"];
        if ([fm fileExistsAtPath:pbSrc]) {
            NSString *pbDst = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"Pasteboard"];
            [fm removeItemAtPath:pbDst error:nil];
            [fm copyItemAtPath:pbSrc toPath:pbDst error:nil];
        }

        [[NDAppDataManager shared] importAMGHolographicFromDirectory:holoSrc intoRecord:saved.name];
        // Also pull apps nested under apps/
        for (NSString *base in @[holoSrc, full]) {
            NSString *nestedApps = [base stringByAppendingPathComponent:@"apps"];
            BOOL nestedDir = NO;
            if ([fm fileExistsAtPath:nestedApps isDirectory:&nestedDir] && nestedDir) {
                [[NDAppDataManager shared] importAMGHolographicFromDirectory:nestedApps intoRecord:saved.name];
            }
        }
        // Persist plaintext AMG faker next to profile when we resolved identity
        if (resolvedPlaintext || resolvedLayout) {
            NSString *dstFaker = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"faker.plist"];
            [saved writeAMGFakerToDirectory:[NDPaths recordDir:saved.name] error:nil];
            (void)dstFaker;
        }
        NSString *appsRoot = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"apps"];
        for (NSString *b in [[self class] discoverAppBundleIdsInDirectory:appsRoot]) [toMerge addObject:b];

        // When faker is ciphertext, seed IDFV from Venmo akc DeviceFingerprint so spoof
        // matches the session Venmo bound in Keychain (better login restore odds).
        if (fakerEncrypted) {
            for (NSString *bid in @[@"net.kortina.labs.Venmo"]) {
                NSString *akcPath = [[appsRoot stringByAppendingPathComponent:bid] stringByAppendingPathComponent:@"Documents/akc.plist"];
                if (![fm fileExistsAtPath:akcPath]) {
                    akcPath = [[appsRoot stringByAppendingPathComponent:bid] stringByAppendingPathComponent:@"akc.plist"];
                }
                NSDictionary *akc = [NSDictionary dictionaryWithContentsOfFile:akcPath];
                if (![akc isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *fpItem = akc[@"VenmoKit_com.venmo.VenmoKit.DeviceFingerprint"];
                NSData *fpData = [fpItem isKindOfClass:[NSDictionary class]] ? fpItem[@"v_Data"] : nil;
                NSString *fp = nil;
                if ([fpData isKindOfClass:[NSData class]] && fpData.length) {
                    fp = [[NSString alloc] initWithData:fpData encoding:NSUTF8StringEncoding];
                }
                if (fp.length >= 32) {
                    saved.IDFV = fp;
                    [self saveProfile:saved error:nil];
                    NSString *notePath = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"];
                    NSString *extra = [NSString stringWithFormat:@"\nSeeded IDFV from Venmo akc DeviceFingerprint=%@.", fp];
                    NSString *prev = [NSString stringWithContentsOfFile:notePath encoding:NSUTF8StringEncoding error:nil] ?: @"";
                    if (![prev containsString:@"Seeded IDFV"]) {
                        [[prev stringByAppendingString:extra] writeToFile:notePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    }
                }
                break;
            }
        }

        if (toMerge.count) {
            // Persist per-record selectApp so switch restores this env
            [toMerge.array writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"selectApp.plist"] atomically:YES];
            [self mergeTargetApps:toMerge.array];
        }

        if (self.importingNames && ![self.importingNames containsObject:saved.name]) {
            [self.importingNames addObject:saved.name];
        }
        // Summarize staged holographic apps (e.g. Venmo Documents/Library)
        NSArray *staged = [fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
        NSMutableArray *bits = [NSMutableArray array];
        for (NSString *bid in staged) {
            NSString *p = [appsRoot stringByAppendingPathComponent:bid];
            BOOL d = NO;
            if (![fm fileExistsAtPath:p isDirectory:&d] || !d) continue;
            unsigned long long bytes = 0;
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:p];
            while ([en nextObject]) {
                NSDictionary *attrs = [en fileAttributes];
                if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) bytes += [attrs fileSize];
            }
            [bits addObject:[NSString stringWithFormat:@"%@ %lluKB", bid, bytes / 1024]];
        }
        if (bits.count && self.importingHoloLines) {
            [self.importingHoloLines addObject:[NSString stringWithFormat:@"%@ → %@", saved.name, [bits componentsJoinedByString:@", "]]];
        }

        // Keychain: stage only during holographic import. Live restore happens on record switch.
        } @catch (NSException *ex) {
            NSString *note = [NSString stringWithFormat:@"record %@ import exception: %@ — %@",
                              entry, ex.name ?: @"?", ex.reason ?: @"?"];
            NSLog(@"[NewDevice] %@", note);
            if (self.importingHoloLines) [self.importingHoloLines addObject:note];
            // Persist immediately so nd-last-import / Filza can show why archiveImport=0
            NSString *crashLog = [@"/var/mobile/Media/AMG/import/nd-last-import.txt" stringByAppendingString:@""];
            NSString *prev = [NSString stringWithContentsOfFile:crashLog encoding:NSUTF8StringEncoding error:nil] ?: @"";
            [[prev stringByAppendingFormat:@"\n%@\n", note] writeToFile:crashLog atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    // Nested under beginImportSession: parent endImportSession notifies once.
    // Standalone call: clean up and notify here.
    if (!nestedInSession) {
        if (!self.lastImportedRecordNames.count && self.importingNames.count) {
            self.lastImportedRecordNames = [self.importingNames copy];
        }
        if (self.importingHoloLines.count) {
            self.lastImportHoloSummary = [self.importingHoloLines componentsJoinedByString:@"\n"];
        }
        self.importingNames = nil;
        self.importingHoloLines = nil;
        if (imported) [self notifyReload];
    }
    return imported;
}

- (void)beginImportSession {
    self.importingNames = [NSMutableArray array];
    self.importingHoloLines = [NSMutableArray array];
    self.lastImportedRecordNames = @[];
    self.lastImportHoloSummary = nil;
}

- (void)endImportSession {
    self.lastImportedRecordNames = [self.importingNames copy] ?: @[];
    if (self.importingHoloLines.count) {
        self.lastImportHoloSummary = [self.importingHoloLines componentsJoinedByString:@"\n"];
    } else if (self.lastImportedRecordNames.count) {
        self.lastImportHoloSummary = @"（记录已导入，但 apps/ 下没有沙盒数据）";
    } else {
        self.lastImportHoloSummary = nil;
    }
    NSUInteger count = self.lastImportedRecordNames.count;
    self.importingNames = nil;
    self.importingHoloLines = nil;
    if (count) [self notifyReload];
}

- (void)writeResultCode:(NSInteger)code {
    [NDPaths ensureDirectories];
    NSString *value = [NSString stringWithFormat:@"%ld", (long)code];
    NSArray<NSString *> *paths = @[
        [NDPaths resultFilePath],
        // AMG drop-in scripts poll /var/mobile/amgResult.txt
        @"/var/mobile/amgResult.txt",
        [[NDPaths jbPrefix] stringByAppendingPathComponent:@"/var/mobile/amgResult.txt"],
        @"/var/mobile/newdeviceResult.txt",
    ];
    NSMutableSet *unique = [NSMutableSet set];
    for (NSString *path in paths) {
        if (!path.length || [unique containsObject:path]) continue;
        [unique addObject:path];
        NSString *dir = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NDPaths makePathWorldReadable:path];
    }
}

- (void)notifyReload {
    // Publish world-readable snapshot BEFORE notify so target apps reload fresh state.
    // Prefer full config.plist for targetApps — runtime.plist alone can be stale/empty
    // and would wipe App environment after AMG import.
    NDConfig *cfg = [NDConfig shared];
    NSDictionary *full = [NSDictionary dictionaryWithContentsOfFile:[NDPaths configPlistPath]];
    [cfg reload];
    if ([full isKindOfClass:[NSDictionary class]] && [full[@"targetApps"] isKindOfClass:[NSArray class]]) {
        NSArray *diskApps = full[@"targetApps"];
        if (diskApps.count >= (cfg.targetApps.count ?: 0)) {
            cfg.targetApps = diskApps;
        } else {
            NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:cfg.targetApps ?: @[]];
            [merged addObjectsFromArray:diskApps];
            cfg.targetApps = merged.array;
        }
    }
    NSString *name = nil;
    NSString *diskName = [NSString stringWithContentsOfFile:[NDPaths currentRecordPointerPath] encoding:NSUTF8StringEncoding error:nil];
    diskName = [diskName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    name = diskName.length ? diskName : [self currentRecordName];
    NDDeviceProfile *profile = name.length ? [self profileNamed:name] : nil;
    [NDRuntimeState publishWithConfig:cfg profile:profile currentName:name];
    notify_post([NDNotifyReload UTF8String]);
}

@end
