#import "NDRecordStore.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import "NDRuntimeState.h"
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

- (void)writeResultCode:(NSInteger)code {
    [NDPaths ensureDirectories];
    [[NSString stringWithFormat:@"%ld", (long)code] writeToFile:[NDPaths resultFilePath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
