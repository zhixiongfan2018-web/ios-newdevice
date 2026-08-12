#import "NDRecordStore.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import "NDRuntimeState.h"
#import "NDAppDataManager.h"
#import <notify.h>

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

- (void)ensureOriginalRecord {
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:[NDPaths recordsRoot] error:nil] ?: @[];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *name in contents) {
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
    if ([p.name isEqualToString:@"原始机器"] || [p.name isEqualToString:@"config"] || [p.name isEqualToString:@"settings"]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:22 userInfo:@{NSLocalizedDescriptionKey: @"Skipped reserved name"}];
        return nil;
    }
    if ([self profileNamed:p.name]) {
        NSString *base = p.name;
        NSInteger suffix = 2;
        while ([self profileNamed:[NSString stringWithFormat:@"%@-%ld", base, (long)suffix]]) {
            suffix++;
        }
        p.name = [NSString stringWithFormat:@"%@-%ld", base, (long)suffix];
    }
    if (![self saveProfile:p error:error]) return nil;
    return p;
}

- (NSString *)uniqueRecordName:(NSString *)preferred {
    NSString *base = preferred.length ? preferred : [[NSDate date] description];
    if ([base isEqualToString:@"原始机器"] || [base isEqualToString:@"config"] || [base isEqualToString:@"settings"]) {
        base = [base stringByAppendingString:@"-import"];
    }
    if (![self profileNamed:base]) return base;
    NSInteger suffix = 2;
    while ([self profileNamed:[NSString stringWithFormat:@"%@-%ld", base, (long)suffix]]) {
        suffix++;
    }
    return [NSString stringWithFormat:@"%@-%ld", base, (long)suffix];
}

- (void)mergeTargetApps:(NSArray *)apps {
    if (![apps isKindOfClass:[NSArray class]] || !apps.count) return;
    NDConfig *cfg = [NDConfig shared];
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:cfg.targetApps ?: @[]];
    for (id item in apps) {
        if ([item isKindOfClass:[NSString class]] && [item length]) [set addObject:item];
    }
    cfg.targetApps = set.array;
    [cfg save];
}

- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir error:(NSError **)error {
    if (!dir.length) dir = @"/var/mobile/AMG";
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:23 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AMG directory not found: %@", dir]}];
        return 0;
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
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:entry];
        BOOL entryIsDir = NO;
        [fm fileExistsAtPath:full isDirectory:&entryIsDir];

        if (!entryIsDir) {
            if (![[entry pathExtension].lowercaseString isEqualToString:@"plist"]) continue;
            if ([metaPlists containsObject:entry.lowercaseString]) continue;
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

        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        NSString *faker = [full stringByAppendingPathComponent:@"faker.plist"];
        if ([fm fileExistsAtPath:faker]) [candidates addObject:faker];
        NSString *profile = [full stringByAppendingPathComponent:@"profile.plist"];
        if ([fm fileExistsAtPath:profile]) [candidates addObject:profile];
        NSArray *inner = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
        for (NSString *f in inner) {
            if (![[f pathExtension].lowercaseString isEqualToString:@"plist"]) continue;
            if ([metaPlists containsObject:f.lowercaseString]) continue;
            if ([f.lowercaseString isEqualToString:@"faker.plist"] || [f.lowercaseString isEqualToString:@"profile.plist"]) continue;
            NSString *p = [full stringByAppendingPathComponent:f];
            if (![candidates containsObject:p]) [candidates addObject:p];
        }

        NDDeviceProfile *saved = nil;
        BOOL fakerEncrypted = NO;
        for (NSString *plistPath in candidates) {
            NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if ([NDDeviceProfile dictionaryLooksLikeEncryptedAMGFaker:raw]) {
                fakerEncrypted = YES;
                continue;
            }
            saved = [self importProfileAtPath:plistPath preferredName:recordName error:nil];
            if (saved) break;
        }

        if (!saved) {
            NSString *unique = [self uniqueRecordName:recordName];
            NDDeviceProfile *fresh = [NDDeviceProfile randomProfileWithName:unique preferredModel:nil preferredSystem:nil];
            if ([self saveProfile:fresh error:nil]) {
                saved = fresh;
                NSString *note = fakerEncrypted
                    ? @"AMG faker.plist was encrypted; generated a new random identity. App holographic data was imported."
                    : @"No plaintext AMG identity plist found; generated a new random identity. App holographic data was imported when present.";
                [note writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"]
                      atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        if (!saved) continue;

        imported++;

        id selectApps = [NSArray arrayWithContentsOfFile:[full stringByAppendingPathComponent:@"selectApp.plist"]];
        if (![selectApps isKindOfClass:[NSArray class]]) {
            NSDictionary *selectDict = [NSDictionary dictionaryWithContentsOfFile:[full stringByAppendingPathComponent:@"selectApp.plist"]];
            if ([selectDict[@"apps"] isKindOfClass:[NSArray class]]) selectApps = selectDict[@"apps"];
        }
        if ([selectApps isKindOfClass:[NSArray class]]) [self mergeTargetApps:selectApps];

        for (NSString *side in @[@"ifaddrs.plist", @"faker.plist", @"description.plist", @"selectApp.plist"]) {
            NSString *src = [full stringByAppendingPathComponent:side];
            if (![fm fileExistsAtPath:src]) continue;
            NSString *dst = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:side];
            [fm removeItemAtPath:dst error:nil];
            [fm copyItemAtPath:src toPath:dst error:nil];
        }
        NSString *pbSrc = [full stringByAppendingPathComponent:@"Pasteboard"];
        if ([fm fileExistsAtPath:pbSrc]) {
            NSString *pbDst = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"Pasteboard"];
            [fm removeItemAtPath:pbDst error:nil];
            [fm copyItemAtPath:pbSrc toPath:pbDst error:nil];
        }

        [[NDAppDataManager shared] importAMGHolographicFromDirectory:full intoRecord:saved.name];
    }
    if (imported) [self notifyReload];
    return imported;
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
    // Publish world-readable snapshot BEFORE notify so target apps reload fresh state
    NDConfig *cfg = [NDConfig shared];
    [cfg reload];
    NSString *name = nil;
    NSString *diskName = [NSString stringWithContentsOfFile:[NDPaths currentRecordPointerPath] encoding:NSUTF8StringEncoding error:nil];
    diskName = [diskName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    name = diskName.length ? diskName : [self currentRecordName];
    NDDeviceProfile *profile = name.length ? [self profileNamed:name] : nil;
    [NDRuntimeState publishWithConfig:cfg profile:profile currentName:name];
    notify_post([NDNotifyReload UTF8String]);
}

@end
