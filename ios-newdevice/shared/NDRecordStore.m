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
            @"amg", @"amg_tar", @"igrimace", @"importdata",
            @"nd-export-stage", @"nd-extract",
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
    if (ok) [self notifyReload];
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

- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir error:(NSError **)error {
    if (!dir.length) dir = @"/var/mobile/AMG_tar";
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:23 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AMG directory not found: %@", dir]}];
        return 0;
    }

    if (!self.importingNames) self.importingNames = [NSMutableArray array];
    if (!self.importingHoloLines) self.importingHoloLines = [NSMutableArray array];

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
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        if ([[self class] isReservedRecordFolderName:entry]) continue;
        NSString *full = [dir stringByAppendingPathComponent:entry];
        BOOL entryIsDir = NO;
        [fm fileExistsAtPath:full isDirectory:&entryIsDir];

        if (!entryIsDir) {
            if (![[entry pathExtension].lowercaseString isEqualToString:@"plist"]) continue;
            if ([metaPlists containsObject:entry.lowercaseString]) continue;
            if ([[self class] isReservedRecordFolderName:[entry stringByDeletingPathExtension]]) continue;
            if ([self importProfileAtPath:full preferredName:[entry stringByDeletingPathExtension] error:nil]) {
                imported++;
            }
            continue;
        }

        NSString *recordName = entry;
        NSDictionary *desc = [NSDictionary dictionaryWithContentsOfFile:[full stringByAppendingPathComponent:@"description.plist"]];
        if ([desc[@"title"] isKindOfClass:[NSString class]] && [desc[@"title"] length]) {
            recordName = desc[@"title"];
        }
        if ([[self class] isReservedRecordFolderName:recordName]) {
            recordName = entry;
            if ([[self class] isReservedRecordFolderName:recordName]) continue;
        }
        recordName = [self sanitizeRecordName:recordName];

        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        // Prefer official plaintext sidecars (getRecordParam / Get_Param output)
        for (NSString *side in [NDAMGParamClient sidecarPlaintextFileNames]) {
            NSString *p = [full stringByAppendingPathComponent:side];
            if ([fm fileExistsAtPath:p]) [candidates addObject:p];
        }
        NSString *faker = [full stringByAppendingPathComponent:@"faker.plist"];
        if ([fm fileExistsAtPath:faker]) [candidates addObject:faker];
        NSString *profile = [full stringByAppendingPathComponent:@"profile.plist"];
        if ([fm fileExistsAtPath:profile]) [candidates addObject:profile];
        NSArray *inner = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
        for (NSString *f in inner) {
            if (![[f pathExtension].lowercaseString isEqualToString:@"plist"]) continue;
            if ([metaPlists containsObject:f.lowercaseString]) continue;
            if ([f.lowercaseString isEqualToString:@"faker.plist"] || [f.lowercaseString isEqualToString:@"profile.plist"]) continue;
            if ([[NDAMGParamClient sidecarPlaintextFileNames] containsObject:f]) continue;
            NSString *p = [full stringByAppendingPathComponent:f];
            if (![candidates containsObject:p]) [candidates addObject:p];
        }

        // App env markers: selectApp / AppGroup / bundle-id folders
        NSArray *discoveredApps = [[self class] discoverAppBundleIdsInDirectory:full];
        BOOL hasHolo = discoveredApps.count > 0
            || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"AppGroup"]]
            || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"Pasteboard"]]
            || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"apps"]]
            || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"selectApp.plist"]];

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

        for (NSString *plistPath in candidates) {
            NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if ([NDDeviceProfile dictionaryLooksLikeEncryptedAMGFaker:raw]) {
                if (!resolvedPlaintext) fakerEncrypted = YES;
                continue;
            }
            saved = [self importProfileAtPath:plistPath preferredName:recordName error:nil];
            if (saved) {
                saved.spoofDeviceIdentity = YES;
                [self saveProfile:saved error:nil];
                if (paramSourceNote.length) {
                    NSString *note = [NSString stringWithFormat:@"Identity from %@ (AMG plaintext API/sidecar).", paramSourceNote];
                    [note writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"]
                          atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
                break;
            }
        }

        // Do NOT invent a record for empty container folders (this created bogus "import"/"export").
        if (!saved) {
            if (!hasHolo && !fakerEncrypted) continue;
            if (!hasHolo) continue;
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

        [[NDAppDataManager shared] importAMGHolographicFromDirectory:full intoRecord:saved.name];
        // Also pull apps nested under apps/
        NSString *nestedApps = [full stringByAppendingPathComponent:@"apps"];
        BOOL nestedDir = NO;
        if ([fm fileExistsAtPath:nestedApps isDirectory:&nestedDir] && nestedDir) {
            [[NDAppDataManager shared] importAMGHolographicFromDirectory:nestedApps intoRecord:saved.name];
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

        // Keychain: stage only during holographic import. Live restore happens on record switch / auto-apply.
    }
    if (imported) [self notifyReload];
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
    self.importingNames = nil;
    self.importingHoloLines = nil;
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
