#import "NDRecordStore.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import "NDRuntimeState.h"
#import "NDAppDataManager.h"
#import "NDAMGParamClient.h"
#import "NDDeviceProfile.h"
#import "NDDeviceCatalog.h"
#import "NDAirplane.h"
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

static BOOL NDRecordStoreSpawn(NSString *launchPath, NSArray<NSString *> *args) {
    if (!launchPath.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:launchPath]) return NO;
    NSUInteger count = args.count;
    char **argv = calloc(count + 2, sizeof(char *));
    if (!argv) return NO;
    argv[0] = (char *)launchPath.fileSystemRepresentation;
    for (NSUInteger i = 0; i < count; i++) {
        argv[i + 1] = (char *)[args[i] fileSystemRepresentation];
    }
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    free(argv);
    if (rc != 0 || pid <= 0) return NO;
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

@interface NDRecordStore ()
@property (nonatomic, copy, readwrite) NSArray<NSString *> *lastImportedRecordNames;
@property (nonatomic, copy, readwrite) NSString *lastImportHoloSummary;
@property (nonatomic, assign, readwrite) NSUInteger lastImportSuccessCount;
@property (nonatomic, assign, readwrite) NSUInteger lastImportFailCount;
@property (nonatomic, assign, readwrite) NSUInteger lastImportSkipCount;
@property (nonatomic, strong) NSMutableArray<NSString *> *importingNames;
@property (nonatomic, strong) NSMutableArray<NSString *> *importingHoloLines;
@end

@implementation NDRecordStore

/// If UDID/IDFA/Serial collide with another record, replace with a fresh unique identity.
- (NDDeviceProfile *)NDEnsureUniqueImportedProfile:(NDDeviceProfile *)p {
    if (!p || !p.name.length) return p;
    BOOL clash = NO;
    for (NSString *otherName in [self allRecordNames]) {
        if ([otherName isEqualToString:p.name] || [otherName isEqualToString:@"原始机器"]) continue;
        NDDeviceProfile *o = [self profileNamed:otherName];
        if (!o) continue;
        if (p.UDID.length && o.UDID.length && [p.UDID.lowercaseString isEqualToString:o.UDID.lowercaseString]) { clash = YES; break; }
        if (p.IDFA.length && o.IDFA.length && [p.IDFA.lowercaseString isEqualToString:o.IDFA.lowercaseString]) { clash = YES; break; }
        if (p.Serial.length && o.Serial.length && [p.Serial isEqualToString:o.Serial]) { clash = YES; break; }
    }
    if (!clash) return p;
    NDDeviceProfile *fresh = [NDDeviceProfile randomProfileWithName:p.name preferredModel:nil preferredSystem:nil];
    fresh.enabled = p.enabled;
    fresh.remark = p.remark ?: @"";
    fresh.spoofDeviceIdentity = YES;
    if ([NDConfig shared].locationFromIP) {
        [fresh applyGeolocation:[NDAirplane fetchIPGeolocationSync] jitter:YES];
    }
    [fresh alignConsistency];
    if ([self saveProfile:fresh error:nil]) {
        NSString *note = @"Identity collided with another record; regenerated UNIQUE spoof profile (App data kept).";
        NSString *path = [[NDPaths recordDir:fresh.name] stringByAppendingPathComponent:@"amg-import-note.txt"];
        NSString *prev = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [[prev stringByAppendingFormat:@"\n%@", note] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return fresh;
    }
    return p;
}

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

- (NSDate *)sortDateForRecordName:(NSString *)name {
    if (!name.length) return [NSDate distantPast];
    // Prefer profile createdAt (written as en_US_POSIX string).
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[NDPaths profilePathForRecord:name]];
    id created = dict[@"createdAt"];
    if ([created isKindOfClass:[NSDate class]]) return (NSDate *)created;
    if ([created isKindOfClass:[NSString class]] && [(NSString *)created length]) {
        static NSDateFormatter *f;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            f = [NSDateFormatter new];
            f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
        });
        NSDate *d = [f dateFromString:created];
        if (!d) {
            static NSDateFormatter *f2;
            static dispatch_once_t once2;
            dispatch_once(&once2, ^{
                f2 = [NSDateFormatter new];
                f2.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                f2.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZ";
            });
            d = [f2 dateFromString:created];
        }
        // NDDeviceProfile write uses: yyyy-MM-dd HH:mm:ss ZZZZ or similar — also try common forms
        if (!d) {
            static NSDateFormatter *f3;
            static dispatch_once_t once3;
            dispatch_once(&once3, ^{
                f3 = [NSDateFormatter new];
                f3.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                f3.dateFormat = @"yyyy-MM-dd HH:mm:ss";
            });
            d = [f3 dateFromString:created];
        }
        if (d) return d;
    }

    // Parse embedded yyyy-MM-dd-HH-mm-ss from folder name (一键新机 / AMG).
    static NSRegularExpression *re;
    static dispatch_once_t reOnce;
    dispatch_once(&reOnce, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{4}-\\d{2}-\\d{2})-(\\d{2})-(\\d{2})-(\\d{2})"
                                                       options:0 error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    if (m) {
        NSString *stamp = [NSString stringWithFormat:@"%@-%@-%@-%@",
                           [name substringWithRange:[m rangeAtIndex:1]],
                           [name substringWithRange:[m rangeAtIndex:2]],
                           [name substringWithRange:[m rangeAtIndex:3]],
                           [name substringWithRange:[m rangeAtIndex:4]]];
        static NSDateFormatter *nf;
        static dispatch_once_t nfOnce;
        dispatch_once(&nfOnce, ^{
            nf = [NSDateFormatter new];
            nf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            nf.timeZone = [NSTimeZone localTimeZone];
            nf.dateFormat = @"yyyy-MM-dd-HH-mm-ss";
        });
        NSDate *parsed = [nf dateFromString:stamp];
        if (parsed) return parsed;
    }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:[NDPaths profilePathForRecord:name] error:nil];
    return attrs.fileModificationDate ?: [NSDate distantPast];
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

    // Stable UX order: 原始机器 first, then newest → oldest (not alphabetic chaos).
    NSMutableDictionary<NSString *, NSDate *> *dates = [NSMutableDictionary dictionary];
    for (NSString *n in names) {
        if ([n isEqualToString:@"原始机器"]) continue;
        dates[n] = [self sortDateForRecordName:n] ?: [NSDate distantPast];
    }
    [names sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL aOrig = [a isEqualToString:@"原始机器"];
        BOOL bOrig = [b isEqualToString:@"原始机器"];
        if (aOrig && !bOrig) return NSOrderedAscending;
        if (!aOrig && bOrig) return NSOrderedDescending;
        if (aOrig && bOrig) return NSOrderedSame;
        NSDate *da = dates[a] ?: [NSDate distantPast];
        NSDate *db = dates[b] ?: [NSDate distantPast];
        NSComparisonResult byDate = [db compare:da]; // newest first
        if (byDate != NSOrderedSame) return byDate;
        return [a localizedStandardCompare:b];
    }];
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
    // Remember the last real environment so closing the app can revert to 本机
    // without forgetting which record to restore when NewDevice is opened again.
    if (value.length && ![value isEqualToString:@"原始机器"]) {
        [value writeToFile:[NDPaths lastSessionRecordPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NDPaths makePathWorldReadable:[NDPaths lastSessionRecordPath]];
    }
}

- (NSString *)lastSessionRecordName {
    NSString *name = [NSString stringWithContentsOfFile:[NDPaths lastSessionRecordPath] encoding:NSUTF8StringEncoding error:nil];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return name.length ? name : nil;
}

- (void)clearLastSessionRecordName {
    [[NSFileManager defaultManager] removeItemAtPath:[NDPaths lastSessionRecordPath] error:nil];
}

+ (BOOL)isNewDeviceUIRunning {
    for (NSString *bin in @[ @"/var/jb/usr/bin/killall", @"/usr/bin/killall" ]) {
        if (NDRecordStoreSpawn(bin, @[ @"-0", @"NewDevice" ])) return YES;
    }
    return NO;
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
    NSMutableArray *sysPool = [NSMutableArray array];
    for (NSString *v in cfg.preferredSystems ?: @[]) {
        if ([NDDeviceCatalog majorSystemVersion:v] >= 18) [sysPool addObject:v];
    }
    NSString *sys = sysPool.count ? sysPool[arc4random_uniform((uint32_t)sysPool.count)] : nil;
    NDDeviceProfile *p = [NDDeviceProfile randomProfileWithName:[self makeRecordName] preferredModel:model preferredSystem:sys];

    // Prefer GPS/timezone from current public IP (avoids US GPS + China IP mismatch).
    if (cfg.locationFromIP && cfg.spoofLocation) {
        NSDictionary *geo = [NDAirplane fetchIPGeolocationSync];
        NSString *note = [p applyGeolocation:geo jitter:cfg.smartLocationOffset];
        if (note.length) NSLog(@"[NewDevice] locationFromIP %@", note);
    } else if (!cfg.randomLocation) {
        NDDeviceProfile *cur = [self currentProfile];
        if (cur && (cur.Latitude != 0 || cur.Longitude != 0)) {
            p.Latitude = cur.Latitude;
            p.Longitude = cur.Longitude;
            p.Altitude = cur.Altitude;
            if (cur.TimeZone.length) p.TimeZone = cur.TimeZone;
        }
    }

    if (cfg.smartLocationOffset && cfg.spoofLocation && !(cfg.locationFromIP && cfg.spoofLocation)) {
        double offsetLat = ((double)arc4random_uniform(200) - 100) / 100000.0;
        double offsetLon = ((double)arc4random_uniform(200) - 100) / 100000.0;
        p.Latitude += offsetLat;
        p.Longitude += offsetLon;
    }

    [p alignConsistency];
    if (![self saveProfile:p error:error]) return nil;
    [self setCurrentRecordName:p.name];
    [self notifyReload];
    return p;
}

- (NDDeviceProfile *)renewRecordNamed:(NSString *)name error:(NSError **)error {
    if (!name.length || [name isEqualToString:@"原始机器"]) {
        if (error) {
            *error = [NSError errorWithDomain:@"NDRecordStore" code:50
                                     userInfo:@{NSLocalizedDescriptionKey: @"请先选中一个环境"}];
        }
        return nil;
    }
    NDDeviceProfile *old = [self profileNamed:name];
    if (!old) {
        if (error) {
            *error = [NSError errorWithDomain:@"NDRecordStore" code:51
                                     userInfo:@{NSLocalizedDescriptionKey: @"环境不存在"}];
        }
        return nil;
    }

    [[NDConfig shared] reload];
    NDConfig *cfg = [NDConfig shared];
    NSString *model = cfg.preferredModels.count ? cfg.preferredModels[arc4random_uniform((uint32_t)cfg.preferredModels.count)] : nil;
    NSMutableArray *sysPool = [NSMutableArray array];
    for (NSString *v in cfg.preferredSystems ?: @[]) {
        if ([NDDeviceCatalog majorSystemVersion:v] >= 18) [sysPool addObject:v];
    }
    NSString *sys = sysPool.count ? sysPool[arc4random_uniform((uint32_t)sysPool.count)] : nil;
    NDDeviceProfile *p = [NDDeviceProfile randomProfileWithName:name preferredModel:model preferredSystem:sys];
    p.remark = old.remark ?: @"";

    if (cfg.locationFromIP && cfg.spoofLocation) {
        NSDictionary *geo = [NDAirplane fetchIPGeolocationSync];
        [p applyGeolocation:geo jitter:cfg.smartLocationOffset];
    }

    [p alignConsistency];
    if (![self saveProfile:p error:error]) return nil;

    // Drop staged sandboxes so this record starts clean with the new identity.
    // afterSwitch will only wipe live apps that have a restore copy (or Venmo
    // on empty) — Kalshi/FanDuel without a stage stay untouched.
    NSString *appsRoot = [[NDPaths recordDir:name] stringByAppendingPathComponent:@"apps"];
    [[NSFileManager defaultManager] removeItemAtPath:appsRoot error:nil];
    NSString *ag = [[NDPaths recordDir:name] stringByAppendingPathComponent:@"AppGroup"];
    [[NSFileManager defaultManager] removeItemAtPath:ag error:nil];

    [self setCurrentRecordName:name];
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

+ (NSString *)preferredAMGLiveRecordNameFrom:(NSString *)raw {
    if (!raw.length) return raw;
    NSString *name = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Resolved folders use underscores: +1916…_2026-… → +1916… 2026-… (AMG live name)
    if ([name hasPrefix:@"+"]) {
        NSRange r = [name rangeOfString:@"_20"];
        if (r.location != NSNotFound) {
            name = [[name substringToIndex:r.location] stringByAppendingFormat:@" %@", [name substringFromIndex:r.location + 1]];
        }
    }
    return name;
}

+ (unsigned long long)countRegularFilesAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;
    if (!isDir) return 1;
    unsigned long long n = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:path];
    for (__unused NSString *rel in en) {
        NSDictionary *attrs = en.fileAttributes;
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) n++;
    }
    return n;
}

+ (BOOL)copyTreeRobustFrom:(NSString *)src to:(NSString *)dst error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:60 userInfo:@{NSLocalizedDescriptionKey: @"copy src missing"}];
        return NO;
    }
    [fm removeItemAtPath:dst error:nil];
    NSString *parent = [dst stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
    NSError *cpErr = nil;
    if ([fm copyItemAtPath:src toPath:dst error:&cpErr]) {
        unsigned long long a = [self countRegularFilesAtPath:src];
        unsigned long long b = [self countRegularFilesAtPath:dst];
        if (a == 0 || b >= (a * 9) / 10) return YES;
    }
    // Fallback: cp -a (handles large AMG trees better on Dopamine)
    [fm removeItemAtPath:dst error:nil];
    for (NSString *bin in @[@"/var/jb/usr/bin/cp", @"/usr/bin/cp", @"/bin/cp"]) {
        if (!NDRecordStoreSpawn(bin, @[@"-a", src, dst])) continue;
        if (![fm fileExistsAtPath:dst]) continue;
        unsigned long long a = [self countRegularFilesAtPath:src];
        unsigned long long b = [self countRegularFilesAtPath:dst];
        if (a == 0 || b >= (a * 9) / 10) return YES;
    }
    if (error) {
        *error = cpErr ?: [NSError errorWithDomain:@"NDRecordStore" code:61
                                         userInfo:@{NSLocalizedDescriptionKey: @"copy tree incomplete"}];
    }
    return NO;
}

/// Build AMG-recognized live tree: /var/mobile/AMG/<liveName>/{faker,apps,AppGroup,...}
- (BOOL)materializeClassicLiveAMGAtName:(NSString *)liveName
                              fakerSrc:(NSString *)fakerSrc
                                cfgDir:(NSString *)cfgDir
                               holoSrc:(NSString *)holoSrc
                                  note:(NSString **)outNote
                                 error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    liveName = [[self class] preferredAMGLiveRecordNameFrom:liveName];
    if (!liveName.length || [liveName hasPrefix:@"."]) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:62 userInfo:@{NSLocalizedDescriptionKey: @"bad live name"}];
        return NO;
    }
    NSString *liveRoot = @"/var/mobile/AMG";
    [fm createDirectoryAtPath:liveRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
    NSString *livePath = [liveRoot stringByAppendingPathComponent:liveName];
    NSString *stage = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"nd-live-stage-%@", [[NSUUID UUID] UUIDString]]];
    [fm removeItemAtPath:stage error:nil];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];

    // faker.plist — AMG needs at-rest ciphertext when available
    if (fakerSrc.length && [fm fileExistsAtPath:fakerSrc]) {
        [fm copyItemAtPath:fakerSrc toPath:[stage stringByAppendingPathComponent:@"faker.plist"] error:nil];
    }
    // Config side files
    if (cfgDir.length && [fm fileExistsAtPath:cfgDir]) {
        for (NSString *name in @[@"description.plist", @"selectApp.plist", @"selectapp.plist", @"ifaddrs.plist"]) {
            NSString *s = [cfgDir stringByAppendingPathComponent:name];
            if (![fm fileExistsAtPath:s]) continue;
            NSString *dstName = [name.lowercaseString isEqualToString:@"selectapp.plist"] ? @"selectApp.plist" : name;
            [fm copyItemAtPath:s toPath:[stage stringByAppendingPathComponent:dstName] error:nil];
        }
        NSString *pb = [cfgDir stringByAppendingPathComponent:@"Pasteboard"];
        if ([fm fileExistsAtPath:pb]) {
            [[self class] copyTreeRobustFrom:pb to:[stage stringByAppendingPathComponent:@"Pasteboard"] error:nil];
        }
    }
    // Holographic trees at classic root
    if (holoSrc.length && [fm fileExistsAtPath:holoSrc]) {
        NSArray *kids = [fm contentsOfDirectoryAtPath:holoSrc error:nil] ?: @[];
        for (NSString *k in kids) {
            if ([k hasPrefix:@"."]) continue;
            NSString *s = [holoSrc stringByAppendingPathComponent:k];
            BOOL d = NO;
            [fm fileExistsAtPath:s isDirectory:&d];
            NSString *dst = [stage stringByAppendingPathComponent:k];
            if (d) {
                [[self class] copyTreeRobustFrom:s to:dst error:nil];
            } else if ([k.pathExtension.lowercaseString isEqualToString:@"plist"]
                       && ![k.lowercaseString isEqualToString:@"faker.plist"]) {
                [fm copyItemAtPath:s toPath:dst error:nil];
            }
        }
    }

    NSString *venmo = [stage stringByAppendingPathComponent:@"net.kortina.labs.Venmo"];
    BOOL hasAkc = [fm fileExistsAtPath:[[venmo stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"akc.plist"]]
        || [fm fileExistsAtPath:[venmo stringByAppendingPathComponent:@"akc.plist"]];
    unsigned long long files = [[self class] countRegularFilesAtPath:stage];
    if (!hasAkc || files < 5) {
        [fm removeItemAtPath:stage error:nil];
        NSString *msg = [NSString stringWithFormat:@"materialize classic incomplete (files=%llu akc=%@) holo=%@",
                         files, hasAkc ? @"YES" : @"NO", holoSrc ?: @"-"];
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:63 userInfo:@{NSLocalizedDescriptionKey: msg}];
        if (outNote) *outNote = msg;
        return NO;
    }

    NSError *mvErr = nil;
    if (![[self class] copyTreeRobustFrom:stage to:livePath error:&mvErr]) {
        [fm removeItemAtPath:stage error:nil];
        if (error) *error = mvErr;
        if (outNote) *outNote = [NSString stringWithFormat:@"live install fail: %@", mvErr.localizedDescription ?: @"?"];
        return NO;
    }
    [fm removeItemAtPath:stage error:nil];
    // chmod tree world-readable for AMG
    [NDPaths makePathWorldReadable:livePath];
    if (outNote) *outNote = [NSString stringWithFormat:@"liveOK %@ files=%llu akc=YES", livePath, files];
    return YES;
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

    // Prefer AMG live name with spaces (from record_name / description / folder)
    NSString *liveName = recordPath.lastPathComponent ?: @"amg-record";
    NSString *recNameFile = [recordPath stringByAppendingPathComponent:@"record_name.txt"];
    NSString *fromFile = [NSString stringWithContentsOfFile:recNameFile encoding:NSUTF8StringEncoding error:nil];
    fromFile = [fromFile stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (fromFile.length) liveName = fromFile;
    NSDictionary *descEarly = [NSDictionary dictionaryWithContentsOfFile:[recordPath stringByAppendingPathComponent:@"description.plist"]];
    if ([descEarly[@"title"] isKindOfClass:[NSString class]] && [descEarly[@"title"] length]) {
        liveName = descEarly[@"title"];
    }
    liveName = [[self class] preferredAMGLiveRecordNameFrom:liveName];
    if ([liveName hasPrefix:@"."] || !liveName.length) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:51 userInfo:@{NSLocalizedDescriptionKey: @"bad classic record name"}];
        if (outNote) *outNote = @"bad name";
        return NO;
    }

    NSString *earlyName = [self sanitizeRecordName:liveName];
    if ([self recordAlreadyImported:earlyName]) {
        if (outNote) *outNote = [NSString stringWithFormat:@"SKIP already imported: %@", earlyName];
        self.lastImportSkipCount += 1;
        return YES;
    }

    // Refuse empty shells before creating any NewDevice record
    NSString *srcVenmo = [recordPath stringByAppendingPathComponent:@"net.kortina.labs.Venmo"];
    BOOL srcAkc = [fm fileExistsAtPath:[[srcVenmo stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"akc.plist"]];
    unsigned long long srcFiles = [[self class] countRegularFilesAtPath:recordPath];
    if (!srcAkc || srcFiles < 5) {
        // Deep search once (apps nested oddly)
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:recordPath];
        for (NSString *rel in en) {
            if (![rel.lastPathComponent isEqualToString:@"net.kortina.labs.Venmo"]) continue;
            NSString *found = [recordPath stringByAppendingPathComponent:rel];
            if ([fm fileExistsAtPath:[[found stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"akc.plist"]]) {
                srcAkc = YES;
                srcVenmo = found;
                break;
            }
        }
    }
    if (!srcAkc) {
        NSString *msg = [NSString stringWithFormat:
                         @"经典包里没有 Venmo/akc（files=%llu）。\n"
                         @"请用桌面原包 +1916… 2026-….tar.gz，不要用只有同名文件夹的空壳。\npath=%@",
                         srcFiles, recordPath];
        [msg writeToFile:@"/var/mobile/Media/AMG/import/nd-import-status.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:54 userInfo:@{NSLocalizedDescriptionKey: msg}];
        if (outNote) *outNote = @"FAIL no Venmo/akc in classic src";
        return NO;
    }

    NSString *liveRoot = @"/var/mobile/AMG";
    NSString *livePath = [liveRoot stringByAppendingPathComponent:liveName];
    BOOL alreadyLive = [recordPath isEqualToString:livePath];
    if (!alreadyLive) {
        NSError *cpErr = nil;
        // Full-tree install (cp -a + file-count verify) — NSFileManager alone often makes empty shells
        if (![[self class] copyTreeRobustFrom:recordPath to:livePath error:&cpErr]) {
            if (error) *error = cpErr ?: [NSError errorWithDomain:@"NDRecordStore" code:52 userInfo:@{NSLocalizedDescriptionKey: @"copy to /var/mobile/AMG failed"}];
            if (outNote) *outNote = [NSString stringWithFormat:@"liveInstall fail: %@", cpErr.localizedDescription ?: @"?"];
            return NO;
        }
        // Verify live Venmo
        NSString *liveVenmo = [livePath stringByAppendingPathComponent:@"net.kortina.labs.Venmo"];
        if (![fm fileExistsAtPath:[[liveVenmo stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"akc.plist"]]) {
            // If src Venmo was nested, materialize from holo parent
            NSString *matNote = nil;
            NSError *matErr = nil;
            BOOL ok = [self materializeClassicLiveAMGAtName:liveName
                                                  fakerSrc:[recordPath stringByAppendingPathComponent:@"faker.plist"]
                                                    cfgDir:recordPath
                                                   holoSrc:[srcVenmo stringByDeletingLastPathComponent]
                                                      note:&matNote
                                                     error:&matErr];
            if (!ok) {
                if (error) *error = matErr ?: [NSError errorWithDomain:@"NDRecordStore" code:55 userInfo:@{NSLocalizedDescriptionKey: @"live AMG missing Venmo/akc after copy"}];
                if (outNote) *outNote = matNote ?: @"live missing akc";
                return NO;
            }
        }
    }
    NSString *src = alreadyLive ? recordPath : livePath;
    [NDPaths makePathWorldReadable:livePath];

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
        // Still create a stub ONLY after live AMG verified — unique random identity
        NDDeviceProfile *fresh = [NDDeviceProfile randomProfileWithName:recordName preferredModel:nil preferredSystem:nil];
        fresh.enabled = YES;
        fresh.spoofDeviceIdentity = YES;
        if ([NDConfig shared].locationFromIP) {
            [fresh applyGeolocation:[NDAirplane fetchIPGeolocationSync] jitter:YES];
        }
        [fresh alignConsistency];
        if ([self saveProfile:fresh error:&impErr]) saved = fresh;
    }
    if (!saved) {
        if (error) *error = impErr ?: [NSError errorWithDomain:@"NDRecordStore" code:53 userInfo:@{NSLocalizedDescriptionKey: @"classic save failed"}];
        if (outNote) *outNote = [NSString stringWithFormat:@"save fail: %@", impErr.localizedDescription ?: @"?"];
        return NO;
    }
    if (!fakerEncrypted && saved.spoofDeviceIdentity == NO) {
        // plaintext identity imported above sets spoof via importProfile; keep YES when we have real IDs
        if (saved.IDFA.length >= 8 || saved.UDID.length >= 8) {
            saved.spoofDeviceIdentity = YES;
            [self saveProfile:saved error:nil];
        }
    }

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

    // Seed IDFV from Venmo akc when faker was ciphertext
    NSString *venmoStaged = [NDPaths appsBackupDirForRecord:saved.name bundleId:@"net.kortina.labs.Venmo"];
    NSString *venmoDocs = [venmoStaged stringByAppendingPathComponent:@"Documents"];
    NSString *akcPath = [venmoDocs stringByAppendingPathComponent:@"akc.plist"];
    if (fakerEncrypted && [fm fileExistsAtPath:akcPath]) {
        NSDictionary *akc = [NSDictionary dictionaryWithContentsOfFile:akcPath];
        NSDictionary *fpItem = akc[@"VenmoKit_com.venmo.VenmoKit.DeviceFingerprint"];
        NSData *fpData = [fpItem isKindOfClass:[NSDictionary class]] ? fpItem[@"v_Data"] : nil;
        if ([fpData isKindOfClass:[NSData class]] && fpData.length >= 32) {
            NSString *fp = [[NSString alloc] initWithData:fpData encoding:NSUTF8StringEncoding];
            if (fp.length >= 32) {
                saved.IDFV = fp;
                saved.spoofDeviceIdentity = YES;
                [self saveProfile:saved error:nil];
            }
        }
    }

    NSString *appsRoot = [[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"apps"];
    NSArray *staged = [fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
    unsigned long long venmoKB = 0;
    NSDirectoryEnumerator *ven = [fm enumeratorAtPath:venmoStaged];
    for (__unused NSString *r in ven) {
        NSDictionary *attrs = ven.fileAttributes;
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) venmoKB += [attrs fileSize];
    }
    venmoKB /= 1024;
    BOOL akc = [fm fileExistsAtPath:akcPath]
        || [fm fileExistsAtPath:[venmoStaged stringByAppendingPathComponent:@"akc.plist"]];
    BOOL liveAkc = [fm fileExistsAtPath:[[[livePath stringByAppendingPathComponent:@"net.kortina.labs.Venmo"]
                                          stringByAppendingPathComponent:@"Documents"]
                                         stringByAppendingPathComponent:@"akc.plist"]];
    unsigned long long liveFiles = [[self class] countRegularFilesAtPath:livePath];

    // Hard fail: do not leave "same-name empty record" as success
    if (!akc || venmoKB < 10 || !liveAkc) {
        NSString *msg = [NSString stringWithFormat:
                         @"FAIL 空壳记录已避免/回滚条件：staged venmoKB=%llu akc=%@ liveAkc=%@ liveFiles=%llu\n"
                         @"live=%@\nsrc=%@\n",
                         venmoKB, akc ? @"YES" : @"NO", liveAkc ? @"YES" : @"NO", liveFiles,
                         livePath, recordPath];
        [msg writeToFile:@"/var/mobile/Media/AMG/import/nd-import-status.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // Remove empty NewDevice record
        [fm removeItemAtPath:[NDPaths recordDir:saved.name] error:nil];
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:56 userInfo:@{NSLocalizedDescriptionKey: msg}];
        if (outNote) *outNote = @"FAIL empty shell (no staged Venmo)";
        return NO;
    }

    // Pointer so restore can find classic live even when ND record name was sanitized
    // (e.g. record=19169699785-2026-… vs live=+19169699785 2026-…).
    NSString *recDir = [NDPaths recordDir:saved.name];
    [liveName writeToFile:[recDir stringByAppendingPathComponent:@"amg-live-name.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [livePath writeToFile:[recDir stringByAppendingPathComponent:@"amg-live-path.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Immediately write holographic into REAL app sandboxes (Containers/…), not only AMG live.
    NSArray *restoreBids = apps.array.count ? apps.array : @[@"net.kortina.labs.Venmo"];
    [[NDAppDataManager shared] terminateApps:restoreBids];
    NSError *restoreErr = nil;
    [[NDAppDataManager shared] restoreAllStagedAppsFromRecord:saved.name error:&restoreErr];
    [[NDAppDataManager shared] restoreAppGroupsForRecord:saved.name];
    NSString *restoreReport = [NDAppDataManager shared].lastRestoreReport ?: @"";
    NSString *sandboxLine = @"sandboxWrite=UNKNOWN";
    if ([restoreReport containsString:@"OK net.kortina.labs.Venmo"] || [restoreReport containsString:@"liveAkc=yes"]) {
        sandboxLine = @"sandboxWrite=OK (Containers Data + akc)";
    } else if ([restoreReport containsString:@"FAIL net.kortina.labs.Venmo"] || [restoreReport containsString:@"未找到数据容器"]) {
        sandboxLine = @"sandboxWrite=FAIL (no container / copy failed — see Media/NewDevice/last-restore.txt)";
    } else if (restoreReport.length) {
        sandboxLine = [@"sandboxWrite=SEE_REPORT " stringByAppendingString:
                       ([restoreReport length] > 180 ? [[restoreReport substringToIndex:180] stringByAppendingString:@"…"] : restoreReport)];
    }
    if (restoreErr) {
        sandboxLine = [sandboxLine stringByAppendingFormat:@" err=%@", restoreErr.localizedDescription ?: @"?"];
    }

    NSString *note = [NSString stringWithFormat:
                      @"Classic AMG write-back OK.\n"
                      @"liveAMG=%@\nliveFiles=%llu liveAkc=YES\n"
                      @"recordsRoot=%@\nrecord=%@\n"
                      @"stagedApps=%@\nvenmoKB=%llu akc=YES\n"
                      @"fakerEncrypted=%@ spoof=%@\n"
                      @"%@\n",
                      livePath, liveFiles,
                      [NDPaths recordsRoot], saved.name,
                      [staged componentsJoinedByString:@","],
                      venmoKB,
                      fakerEncrypted ? @"YES" : @"NO",
                      saved.spoofDeviceIdentity ? @"YES" : @"NO",
                      sandboxLine];
    [note writeToFile:[recDir stringByAppendingPathComponent:@"amg-import-note.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [note writeToFile:@"/var/mobile/Media/AMG/import/nd-import-status.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (![self.importingNames containsObject:saved.name]) [self.importingNames addObject:saved.name];
    [self.importingHoloLines addObject:[NSString stringWithFormat:@"classic %@ → live=%@ apps=%lu venmoKB=%llu akc=YES %@",
                                        saved.name, liveName, (unsigned long)staged.count, venmoKB, sandboxLine]];
    if (outNote) {
        *outNote = [NSString stringWithFormat:@"OK classic→/var/mobile/AMG/%@ venmoKB=%llu akc=YES liveFiles=%llu %@",
                    liveName, venmoKB, liveFiles, sandboxLine];
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
    NSString *liveName = folder;
    NSString *recNameFile = [idDir stringByAppendingPathComponent:@"record_name.txt"];
    NSString *fromFile = [NSString stringWithContentsOfFile:recNameFile encoding:NSUTF8StringEncoding error:nil];
    fromFile = [fromFile stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (fromFile.length) liveName = fromFile;
    NSDictionary *desc = [NSDictionary dictionaryWithContentsOfFile:[cfgDir stringByAppendingPathComponent:@"description.plist"]];
    if (![desc isKindOfClass:[NSDictionary class]]) {
        desc = [NSDictionary dictionaryWithContentsOfFile:[recordPath stringByAppendingPathComponent:@"description.plist"]];
    }
    if ([desc isKindOfClass:[NSDictionary class]] && [desc[@"title"] isKindOfClass:[NSString class]] && [desc[@"title"] length]) {
        liveName = desc[@"title"];
    }
    liveName = [[self class] preferredAMGLiveRecordNameFrom:liveName];
    NSString *recordName = [self sanitizeRecordName:liveName];
    if ([self recordAlreadyImported:recordName]) {
        if (outNote) *outNote = [NSString stringWithFormat:@"SKIP already imported: %@", recordName];
        self.lastImportSkipCount += 1;
        return YES;
    }

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
        fresh.spoofDeviceIdentity = YES;
        if ([NDConfig shared].locationFromIP) {
            [fresh applyGeolocation:[NDAirplane fetchIPGeolocationSync] jitter:YES];
        }
        [fresh alignConsistency];
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

    // Rebuild AMG-recognized classic tree from resolved parts (ciphertext faker + 02_ + 03_)
    NSString *cipherFaker = [idDir stringByAppendingPathComponent:@"faker.plist.ciphertext"];
    if (![fm fileExistsAtPath:cipherFaker]) cipherFaker = [idDir stringByAppendingPathComponent:@"faker.plist"];
    NSString *liveNote = nil;
    NSError *liveErr = nil;
    BOOL liveOK = [self materializeClassicLiveAMGAtName:liveName
                                              fakerSrc:cipherFaker
                                                cfgDir:cfgDir
                                               holoSrc:holoSrc
                                                  note:&liveNote
                                                 error:&liveErr];

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

    if ((!akc || venmoKB < 10) && !liveOK) {
        NSString *msg = [NSString stringWithFormat:
                         @"FAIL resolved 只建了空壳：venmoKB=%llu akc=%@ live=%@\n%@\n",
                         venmoKB, akc ? @"YES" : @"NO", liveOK ? @"YES" : @"NO",
                         liveNote ?: (liveErr.localizedDescription ?: @"")];
        [msg writeToFile:@"/var/mobile/Media/AMG/import/nd-import-status.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fm removeItemAtPath:[NDPaths recordDir:saved.name] error:nil];
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:43 userInfo:@{NSLocalizedDescriptionKey: msg}];
        if (outNote) *outNote = @"FAIL empty resolved shell";
        return NO;
    }

    NSString *note = [NSString stringWithFormat:
                      @"AMG_resolved → NewDevice + classic live rebuild.\n"
                      @"liveAMG=/var/mobile/AMG/%@\nlive=%@ (%@)\n"
                      @"recordsRoot=%@\nrecord=%@\nholoSrc=%@\nstagedApps=%@\nvenmoKB=%llu akc=%@\n",
                      liveName, liveOK ? @"YES" : @"NO", liveNote ?: @"-",
                      [NDPaths recordsRoot], saved.name, holoSrc,
                      [staged componentsJoinedByString:@","],
                      venmoKB, akc ? @"YES" : @"NO"];
    [note writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [note writeToFile:@"/var/mobile/Media/AMG/import/nd-import-status.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (![self.importingNames containsObject:saved.name]) [self.importingNames addObject:saved.name];
    [self.importingHoloLines addObject:[NSString stringWithFormat:@"%@ → apps=%lu venmoKB=%llu akc=%@ live=%@",
                                        saved.name, (unsigned long)staged.count, venmoKB,
                                        akc ? @"YES" : @"NO", liveOK ? @"YES" : @"NO"]];
    if (outNote) {
        *outNote = [NSString stringWithFormat:@"OK %@ venmoKB=%llu akc=%@ live=%@",
                    saved.name, venmoKB, akc ? @"YES" : @"NO", liveOK ? @"YES" : @"NO"];
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
        if ([self recordAlreadyImported:recordName]) {
            self.lastImportSkipCount += 1;
            [self.importingHoloLines addObject:[NSString stringWithFormat:@"SKIP %@ (already)", recordName]];
            continue;
        }
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
            // Always unique spoofed identity per import. Venmo session is isolated via
            // sandbox + akc / pending-clear-kc — do NOT leave spoof off (that made every
            // env show the same physical device params).
            fresh.spoofDeviceIdentity = YES;
            // Best-effort: seed Wi‑Fi MAC from ifaddrs.plist when present
            NSDictionary *ifa = [NSDictionary dictionaryWithContentsOfFile:[full stringByAppendingPathComponent:@"ifaddrs.plist"]];
            NSDictionary *en0 = [ifa[@"en0"] isKindOfClass:[NSDictionary class]] ? ifa[@"en0"] : nil;
            NSString *mac = [en0[@"mac"] isKindOfClass:[NSString class]] ? en0[@"mac"] : nil;
            if (mac.length && ![mac isEqualToString:@"02:00:00:00:00:00"]) {
                fresh.WiFiMAC = mac;
                fresh.BTMAC = mac; // aligned later by alignConsistency if needed
            }
            if ([NDConfig shared].locationFromIP) {
                NSDictionary *geo = [NDAirplane fetchIPGeolocationSync];
                [fresh applyGeolocation:geo jitter:YES];
            }
            [fresh alignConsistency];
            if ([self saveProfile:fresh error:nil]) {
                saved = fresh;
                NSString *note = fakerEncrypted
                    ? [NSString stringWithFormat:@"faker ciphertext; no per-record plaintext (%@). Generated UNIQUE random identity + imported App/akc. Optional: add faker_plaintext.plist and re-import for AMG's original MG.", paramSourceNote ?: @"-"]
                    : @"No plaintext AMG identity; generated a unique random identity. App holographic data imported when present.";
                [note writeToFile:[[NDPaths recordDir:saved.name] stringByAppendingPathComponent:@"amg-import-note.txt"]
                      atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        if (!saved) continue;
        // If this identity collides with another record (common when a shared
        // plaintext/current-param was applied), regenerate a unique spoof profile.
        saved = [self NDEnsureUniqueImportedProfile:saved] ?: saved;
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
    self.lastImportSuccessCount = 0;
    self.lastImportFailCount = 0;
    self.lastImportSkipCount = 0;
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
    // Prefer explicit success list size; keep fail/skip as accumulated during pass.
    self.lastImportSuccessCount = self.lastImportedRecordNames.count;
    NSUInteger count = self.lastImportedRecordNames.count;
    self.importingNames = nil;
    self.importingHoloLines = nil;
    if (count) [self notifyReload];
}

- (BOOL)recordAlreadyImported:(NSString *)name {
    if (!name.length || [name isEqualToString:@"原始机器"]) return NO;
    NSString *path = [NDPaths profilePathForRecord:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    // Prefer skip when apps already staged; bare profile also counts as present.
    return YES;
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

- (NSString *)refreshLocationFromCurrentIP {
    return [self refreshLocationFromCurrentIPForce:NO];
}

- (NSString *)refreshLocationFromCurrentIPForce:(BOOL)force {
    static BOOL inflight = NO;
    static NSTimeInterval lastAttempt = 0;
    @synchronized (self) {
        NSTimeInterval now = [[NSDate date] timeIntervalSinceReferenceDate];
        if (!force) {
            if (inflight) return @"";
            if ((now - lastAttempt) < 75.0) return @"";
        }
        inflight = YES;
        lastAttempt = now;
    }

    NSString *note = @"";
    @try {
        [[NDConfig shared] reload];
        NDConfig *cfg = [NDConfig shared];
        if (!cfg.locationFromIP || !cfg.spoofLocation) {
            return @"";
        }
        NSString *name = [self currentRecordName];
        if (!name.length || [name isEqualToString:@"原始机器"]) return @"";
        NDDeviceProfile *p = [self profileNamed:name];
        if (!p || !p.enabled) return @"";

        NSDictionary *geo = [NDAirplane fetchIPGeolocationSync];
        note = [p applyGeolocation:geo jitter:cfg.smartLocationOffset];
        if (note.length) {
            [self saveProfile:p error:nil];
            NSLog(@"[NewDevice] locationFromIP %@", note);
        }
    } @finally {
        @synchronized (self) { inflight = NO; }
    }
    return note;
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
