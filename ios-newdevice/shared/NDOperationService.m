#import "NDOperationService.h"
#import "NDRecordStore.h"
#import "NDRecordStore+ImportExport.h"
#import "NDConfig.h"
#import "NDAppDataManager.h"
#import "NDAirplane.h"
#import "NDPaths.h"
#import "NDDeviceProfile.h"

@implementation NDOperationService

+ (instancetype)shared {
    static NDOperationService *svc;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        svc = [NDOperationService new];
    });
    return svc;
}

/// Serialize all mutating ops so two setRecord/newRecord cannot interleave wipe/bind.
- (dispatch_queue_t)mutateQueue {
    static dispatch_queue_t q;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.local.newdevice.mutate", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

+ (BOOL)isAsyncAckFun:(NSString *)fun {
    static NSSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"newRecord", @"originRecord", @"nextRecord", @"firstRecord", @"prevRecord", @"previousRecord", @"setRecord",
            @"deleteRecord", @"deleteAllRecords",
            @"disableRecord", @"enableRecord", @"disableAllRecord", @"enableAllRecord",
            @"setRecordName", @"setCurrentRecordParam", @"setRecordParam",
            @"clearAppData", @"cleanApps", @"importAMGRecords",
            @"importIGrimace", @"importAWZ", @"importAMGMedia",
            @"exportAMGMedia", @"slimRecord", @"restoreHolo",
            @"clearVenmoKeychain", @"purgeVenmo", @"clearAppKeychain",
            @"respring", @"sbreload",
        ]];
    });
    return fun.length && [set containsObject:fun];
}

- (NSArray<NSString *> *)appsForSwitchTo:(NSString *)current previous:(NSString *)previous {
    [[NDConfig shared] reload];
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:[NDConfig shared].targetApps ?: @[]];
    for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:current]) [set addObject:b];
    for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:previous]) [set addObject:b];
    // Keep global targetApps in sync so「目标应用」页能看到导入的 App 环境
    if (set.count && set.count != ([NDConfig shared].targetApps.count ?: 0)) {
        [NDConfig shared].targetApps = set.array;
        [[NDConfig shared] save];
    }
    return set.array;
}

- (void)prepareTargets:(void (^)(NSArray<NSString *> *apps, NSString *previousRecord))block {
    [self prepareTargetsForDestination:nil block:block];
}

- (void)prepareTargetsForDestination:(NSString *)destination
                               block:(void (^)(NSArray<NSString *> *apps, NSString *previousRecord))block {
    NSString *prev = [[NDRecordStore shared] currentRecordName] ?: @"原始机器";
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:[self appsForSwitchTo:prev previous:prev]];
    // Include destination App env BEFORE kill/restore (imported Venmo etc.)
    if (destination.length) {
        for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:destination]) [set addObject:b];
    }
    NSArray *apps = set.array;
    [[NDAppDataManager shared] terminateApps:apps];
    block(apps, prev);
}

- (BOOL)recordHasStagedApps:(NSString *)name {
    if (!name.length || [name isEqualToString:@"原始机器"]) return NO;
    NSString *appsRoot = [[NDPaths recordDir:name] stringByAppendingPathComponent:@"apps"];
    NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
    for (NSString *e in entries) {
        if ([e hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[appsRoot stringByAppendingPathComponent:e] isDirectory:&isDir] && isDir) {
            return YES;
        }
    }
    return NO;
}

- (void)afterSwitchFrom:(NSString *)previous to:(NSString *)current apps:(NSArray<NSString *> *)apps {
    NDConfig *cfg = [NDConfig shared];
    @try {
        // Destination record apps only — do NOT permanently union every historical import
        // into global targetApps (that bloated lists and broke 一键新机 with huge backups).
        NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:cfg.targetApps ?: @[]];
        for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:current]) [set addObject:b];
        // Working set for this switch: configured targets + both records' apps
        NSMutableOrderedSet *work = [NSMutableOrderedSet orderedSetWithArray:apps ?: @[]];
        for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:current]) [work addObject:b];
        for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:previous]) [work addObject:b];
        apps = work.array;
        if (set.count) {
            cfg.targetApps = set.array;
            [cfg save];
        }

        BOOL hasStaged = [self recordHasStagedApps:current];
        if (cfg.holographicBackup && apps.count) {
            BOOL sameRecord = previous.length && current.length && [previous isEqualToString:current];
            BOOL leavingReal = !sameRecord && previous.length && ![previous isEqualToString:@"原始机器"];

            // Snapshot outgoing live data when leaving a real record.
            // Keep fat AMG stages (fat-guard in backupApps); never skip backup just
            // because destination is empty — otherwise live divergence is lost.
            if (leavingReal) {
                NSArray *prevApps = [[NDRecordStore shared] appBundleIdsForRecord:previous];
                if (!prevApps.count) prevApps = apps;
                [[NDAppDataManager shared] backupApps:prevApps toRecord:previous error:nil];
            }

            // Always wipe live sandboxes so the new identity cannot inherit files.
            [[NDAppDataManager shared] clearDataForApps:apps error:nil];
            if (hasStaged && ![current isEqualToString:@"原始机器"]) {
                NSError *restoreErr = nil;
                [[NDAppDataManager shared] restoreAllStagedAppsFromRecord:current error:&restoreErr];
                [[NDAppDataManager shared] restoreAppGroupsForRecord:current];
                if (restoreErr) NSLog(@"[NewDevice] restore warning: %@", restoreErr.localizedDescription);
                // Strict isolation: previous Venmo Keychain must not leak into this record.
                if ([apps containsObject:@"net.kortina.labs.Venmo"]) {
                    NSString *bind = [[NDAppDataManager shared] bindVenmoKeychainToCurrentRecord];
                    NSLog(@"[NewDevice] bindVenmo %@", bind);
                }
            } else if ([apps containsObject:@"net.kortina.labs.Venmo"]) {
                // Empty 一键新机 / 原始机器: must clear Venmo Keychain in-app or the
                // old account survives uninstall+redownload.
                [[NDAppDataManager shared] purgeVenmoSessionInApp];
            }
        } else if (apps.count) {
            [[NDAppDataManager shared] clearDataForApps:apps error:nil];
            if ([apps containsObject:@"net.kortina.labs.Venmo"]) {
                [[NDAppDataManager shared] purgeVenmoSessionInApp];
            }
        }

        if (cfg.clearPasteboardOnSwitch) {
            NDAppDataManager *adm = [NDAppDataManager shared];
            if (previous.length && ![previous isEqualToString:@"原始机器"]) {
                [adm backupPasteboardToRecord:previous];
            }
            if ([current isEqualToString:@"原始机器"]) {
                [adm clearGeneralPasteboard];
            } else {
                [adm restorePasteboardFromRecord:current];
            }
        }
        if (cfg.smartAirplane) {
            [NDAirplane toggleAirplaneWithDelay:3.0 error:nil];
        }
    } @catch (NSException *ex) {
        NSLog(@"[NewDevice] afterSwitch exception: %@", ex);
        // Never leave result stuck at 2 — identity switch already happened
    }
}

- (void)runAsync:(NSString *)fun query:(NSDictionary<NSString *,NSString *> *)query completion:(void (^)(NSString * _Nullable, NSInteger))completion {
    void (^done)(NSString *, NSInteger) = ^(NSString *body, NSInteger code) {
        if (completion) completion(body, code);
    };

    dispatch_async([self mutateQueue], ^{
        [[NDRecordStore shared] writeResultCode:2];
        NSError *error = nil;
        NSString *body = @"";
        BOOL ok = YES;

        if ([fun isEqualToString:@"newRecord"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                NDDeviceProfile *p = [[NDRecordStore shared] createNewRecordAndActivate:&err];
                if (!p) {
                    [[NDRecordStore shared] writeResultCode:0];
                    done(@"", 500);
                    return;
                }
                // Wipe previous live env BEFORE ack — otherwise UI/AMG scripts think
                // 一键新机 finished while Venmo still shows the old environment.
                [self afterSwitchFrom:previousRecord to:p.name apps:apps];
                [[NDRecordStore shared] writeResultCode:1];
                done(p.name, 200);
            }];
            return;
        }

        if ([fun isEqualToString:@"originRecord"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] switchToOriginal:&err];
                if (success) [self afterSwitchFrom:previousRecord to:@"原始机器" apps:apps];
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(success ? @"原始机器" : @"", success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"nextRecord"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] switchToNext:&err];
                NSString *cur = [[NDRecordStore shared] currentRecordName] ?: @"";
                if (success) [self afterSwitchFrom:previousRecord to:cur apps:apps];
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(cur, success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"firstRecord"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] switchToFirst:&err];
                NSString *cur = [[NDRecordStore shared] currentRecordName] ?: @"";
                if (success) [self afterSwitchFrom:previousRecord to:cur apps:apps];
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(cur, success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"prevRecord"] || [fun isEqualToString:@"previousRecord"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] switchToPrevious:&err];
                NSString *cur = [[NDRecordStore shared] currentRecordName] ?: @"";
                if (success) [self afterSwitchFrom:previousRecord to:cur apps:apps];
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(cur, success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"getRecordCount"]) {
            NSUInteger count = [[NDRecordStore shared] allRecordNames].count;
            body = [NSString stringWithFormat:@"%lu", (unsigned long)count];
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        if ([fun isEqualToString:@"setRecord"]) {
            NSString *name = query[@"recordName"] ?: @"";
            [self prepareTargetsForDestination:name block:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] switchToRecord:name error:&err];
                if (success) {
                    // Isolation (wipe/bind) MUST finish before ACK — same as newRecord.
                    [self afterSwitchFrom:previousRecord to:name apps:apps];
                    [[NDRecordStore shared] writeResultCode:1];
                } else {
                    [[NDRecordStore shared] writeResultCode:0];
                }
                NSString *report = [NDAppDataManager shared].lastRestoreReport ?: @"";
                NSString *msg = success
                    ? [NSString stringWithFormat:@"%@\n\n%@", name, report]
                    : (err.localizedDescription ?: name);
                done(msg, success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"restoreHolo"]) {
            NSString *name = query[@"recordName"] ?: [[NDRecordStore shared] currentRecordName] ?: @"";
            if (!name.length || [name isEqualToString:@"原始机器"]) {
                [[NDRecordStore shared] writeResultCode:0];
                done(@"无当前记录", 500);
                return;
            }
            // Ensure Venmo is a target so identity spoof + tweak paths stay armed
            NDConfig *cfg = [NDConfig shared];
            NSMutableOrderedSet *apps = [NSMutableOrderedSet orderedSetWithArray:cfg.targetApps ?: @[]];
            [apps addObject:@"net.kortina.labs.Venmo"];
            for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:name]) [apps addObject:b];
            if (apps.count != (cfg.targetApps.count ?: 0)) {
                cfg.targetApps = apps.array;
                [cfg save];
            }
            NSArray *bids = apps.array;
            [[NDAppDataManager shared] terminateApps:bids];
            NSMutableArray *lines = [NSMutableArray array];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *appsRoot = [[NDPaths recordDir:name] stringByAppendingPathComponent:@"apps"];
            for (NSString *bid in ([fm contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[])) {
                if ([bid hasPrefix:@"."]) continue;
                if (![[NDAppDataManager shared] containerPathForBundleId:bid]) {
                    [[NDAppDataManager shared] tryLaunchAppToCreateContainer:bid];
                    [lines addObject:[NSString stringWithFormat:@"launch-try %@", bid]];
                }
            }
            NSError *err = nil;
            [[NDAppDataManager shared] restoreAllStagedAppsFromRecord:name error:&err];
            [[NDAppDataManager shared] restoreAppGroupsForRecord:name];
            // Clear previous Venmo session then apply this record's akc (in-app).
            NSString *bind = [[NDAppDataManager shared] bindVenmoKeychainToCurrentRecord] ?: @"";
            NSString *probe = [[NDAppDataManager shared] probeLiveContainerForBundleId:@"net.kortina.labs.Venmo"];
            NSString *report = [NDAppDataManager shared].lastRestoreReport ?: err.localizedDescription ?: @"";
            if (lines.count) report = [NSString stringWithFormat:@"%@\n%@", [lines componentsJoinedByString:@"\n"], report];
            report = [NSString stringWithFormat:@"%@\n--- bindVenmo ---\n%@\n--- probe ---\n%@",
                      report, bind, probe ?: @""];
            [report writeToFile:@"/var/mobile/Media/NewDevice/last-restore.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NDRecordStore shared] writeResultCode:1];
            done(report, 200);
            return;
        }

        if ([fun isEqualToString:@"probeApp"] || [fun isEqualToString:@"probeVenmo"]) {
            NSString *bid = query[@"bundleId"] ?: @"net.kortina.labs.Venmo";
            body = [[NDAppDataManager shared] probeLiveContainerForBundleId:bid] ?: @"";
            // Mirror for Filza / getLastImportLog adjacency
            [body writeToFile:@"/var/mobile/Media/NewDevice/last-probe.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NDRecordStore shared] writeResultCode:body.length ? 1 : 0];
            done(body, body.length ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"probeInject"] || [fun isEqualToString:@"probeTweak"] || [fun isEqualToString:@"probeInjection"]) {
            body = [[NDAppDataManager shared] probeTweakInjection] ?: @"";
            [body writeToFile:@"/var/mobile/Media/NewDevice/last-inject-probe.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NDRecordStore shared] writeResultCode:body.length ? 1 : 0];
            done(body, body.length ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"clearAppKeychain"] || [fun isEqualToString:@"clearVenmoKeychain"] || [fun isEqualToString:@"purgeVenmo"]) {
            NSString *bid = query[@"bundleId"] ?: @"net.kortina.labs.Venmo";
            if ([bid isEqualToString:@"net.kortina.labs.Venmo"] || [fun isEqualToString:@"clearVenmoKeychain"] || [fun isEqualToString:@"purgeVenmo"]) {
                body = [[NDAppDataManager shared] purgeVenmoSessionInApp] ?: @"";
            } else {
                body = [[NDAppDataManager shared] clearKeychainAccessGroupForBundleId:bid] ?: @"";
            }
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        if ([fun isEqualToString:@"disableTweak"] || [fun isEqualToString:@"disableTweakInject"]) {
            body = [[NDAppDataManager shared] setTweakInjectionEnabled:NO] ?: @"";
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        if ([fun isEqualToString:@"enableTweak"] || [fun isEqualToString:@"enableTweakInject"]) {
            body = [[NDAppDataManager shared] setTweakInjectionEnabled:YES] ?: @"";
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        if ([fun isEqualToString:@"clearSafeMode"] || [fun isEqualToString:@"disableSafeMode"] || [fun isEqualToString:@"clearEksafemode"]) {
            body = [[NDAppDataManager shared] clearElleKitSafeMode] ?: @"";
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        if ([fun isEqualToString:@"respring"] || [fun isEqualToString:@"sbreload"]) {
            body = [[NDAppDataManager shared] respringSpringBoard] ?: @"respring";
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        if ([fun isEqualToString:@"getTargetApps"]) {
            NSArray *targets = [NDConfig shared].targetApps ?: [NSArray array];
            body = [targets componentsJoinedByString:@"\n"];
            [[NDRecordStore shared] writeResultCode:1];
            done(body ?: @"", 200);
            return;
        }

        if ([fun isEqualToString:@"getLastImportLog"] || [fun isEqualToString:@"getImportLog"]) {
            NSArray *paths = @[
                @"/var/mobile/Media/AMG/import/nd-last-import.txt",
                @"/var/mobile/Media/AMG/import/nd-import-status.txt",
                @"/var/mobile/Media/NewDevice/last-restore.txt",
                @"/var/mobile/Media/NewDevice/last-probe.txt",
                @"/var/mobile/Media/NewDevice/import/nd-last-import.txt",
                @"/var/mobile/AMG_tar/nd-last-import.txt",
            ];
            NSMutableArray *chunks = [NSMutableArray array];
            for (NSString *p in paths) {
                NSString *t = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
                if (t.length) {
                    [chunks addObject:[NSString stringWithFormat:@"===== %@ =====\n%@", p, t]];
                } else {
                    [chunks addObject:[NSString stringWithFormat:@"===== %@ =====\n(missing)", p]];
                }
            }
            body = [chunks componentsJoinedByString:@"\n\n"];
            // Mirror into CrashReporter for USB pull when Media AFC is unavailable
            [body writeToFile:@"/var/mobile/Library/Logs/CrashReporter/nd-last-import.txt"
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NDRecordStore shared] writeResultCode:1];
            done(body.length ? body : @"(empty)", 200);
            return;
        }

        if ([fun isEqualToString:@"getCurrentRecordName"]) {
            body = [[NDRecordStore shared] currentRecordName] ?: @"";
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        if ([fun isEqualToString:@"getAllRecordNames"]) {
            NSArray *names = [[NDRecordStore shared] allRecordNames];
            NSString *savePath = query[@"saveFilePath"];
            if (savePath.length) {
                [names writeToFile:savePath atomically:YES];
            }
            body = [names componentsJoinedByString:@"\n"];
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        if ([fun isEqualToString:@"setRecordName"]) {
            ok = [[NDRecordStore shared] renameRecord:query[@"oldName"] ?: @"" to:query[@"newName"] ?: @"" error:&error];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(@"", ok ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"deleteRecord"]) {
            ok = [[NDRecordStore shared] deleteRecord:query[@"recordName"] ?: @"" error:&error];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(@"", ok ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"deleteAllRecords"]) {
            ok = [[NDRecordStore shared] deleteAllRecordsKeepingCurrent:YES error:&error];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(@"", ok ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"disableRecord"]) {
            ok = [[NDRecordStore shared] setEnabled:NO forRecord:query[@"recordName"] ?: @"" error:&error];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(@"", ok ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"enableRecord"]) {
            ok = [[NDRecordStore shared] setEnabled:YES forRecord:query[@"recordName"] ?: @"" error:&error];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(@"", ok ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"disableAllRecord"]) {
            ok = [[NDRecordStore shared] setEnabledForAll:NO error:&error];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(@"", ok ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"enableAllRecord"]) {
            ok = [[NDRecordStore shared] setEnabledForAll:YES error:&error];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(@"", ok ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"getCurrentRecordParam"]) {
            NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
            NSString *savePath = query[@"saveFilePath"];
            if (p && savePath.length) {
                [p writeToPath:savePath error:&error];
            }
            body = p ? [[NSString alloc] initWithData:[NSPropertyListSerialization dataWithPropertyList:[p toDictionary] format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] encoding:NSUTF8StringEncoding] : @"";
            [[NDRecordStore shared] writeResultCode:p ? 1 : 0];
            done(body ?: @"", p ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"getAMGFaker"] || [fun isEqualToString:@"exportAMGFaker"]) {
            NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
            NSString *dir = query[@"dir"] ?: query[@"saveFilePath"];
            if (p && dir.length) {
                [p writeAMGFakerToDirectory:dir error:&error];
                NSString *ifaSrc = [NDPaths ifaddrsPathForRecord:p.name];
                if ([[NSFileManager defaultManager] fileExistsAtPath:ifaSrc]) {
                    [[NSFileManager defaultManager] copyItemAtPath:ifaSrc toPath:[dir stringByAppendingPathComponent:@"ifaddrs.plist"] error:nil];
                }
                NSArray *apps = [NDConfig shared].targetApps ?: @[];
                [apps writeToFile:[dir stringByAppendingPathComponent:@"selectApp.plist"] atomically:YES];
            }
            body = p ? [[NSString alloc] initWithData:[NSPropertyListSerialization dataWithPropertyList:[p toAMGFakerDictionary] format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] encoding:NSUTF8StringEncoding] : @"";
            [[NDRecordStore shared] writeResultCode:p ? 1 : 0];
            done(body ?: @"", p ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"getRecordParam"]) {
            NSString *name = query[@"recordName"] ?: @"";
            NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
            NSString *savePath = query[@"saveFilePath"];
            if (p && savePath.length) [p writeToPath:savePath error:&error];
            body = p ? [[NSString alloc] initWithData:[NSPropertyListSerialization dataWithPropertyList:[p toDictionary] format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] encoding:NSUTF8StringEncoding] : @"";
            [[NDRecordStore shared] writeResultCode:p ? 1 : 0];
            done(body ?: @"", p ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"setCurrentRecordParam"] || [fun isEqualToString:@"setRecordParam"]) {
            NSString *filePath = query[@"filePath"] ?: @"";
            NSString *name = query[@"recordName"] ?: [[NDRecordStore shared] currentRecordName];
            NDDeviceProfile *p = nil;
            NSString *b64 = query[@"plistBase64"] ?: query[@"base64"] ?: @"";
            if (b64.length) {
                NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
                if (data.length) {
                    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nd-set-param.plist"];
                    [data writeToFile:tmp atomically:YES];
                    p = [NDDeviceProfile profileAtPath:tmp];
                }
            }
            if (!p) p = [NDDeviceProfile profileAtPath:filePath];
            if (!p) {
                [[NDRecordStore shared] writeResultCode:0];
                done(@"need filePath or plistBase64", 500);
                return;
            }
            if (name.length) p.name = name;
            ok = [[NDRecordStore shared] saveProfile:p error:&error];
            if (ok && [fun isEqualToString:@"setCurrentRecordParam"]) {
                [[NDRecordStore shared] setCurrentRecordName:p.name];
                [[NDRecordStore shared] notifyReload];
            }
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(ok ? @"ok" : (error.localizedDescription ?: @""), ok ? 200 : 500);
            return;
        }

        // AMG-style: clear target apps without generating a new identity
        if ([fun isEqualToString:@"clearAppData"] || [fun isEqualToString:@"cleanApps"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                (void)previousRecord;
                NSError *err = nil;
                BOOL success = [[NDAppDataManager shared] clearDataForApps:apps error:&err];
                NSString *extra = @"";
                if ([apps containsObject:@"net.kortina.labs.Venmo"]) {
                    extra = [[NDAppDataManager shared] purgeVenmoSessionInApp] ?: @"";
                }
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                NSString *msg = success ? (extra.length ? [@"cleared\n" stringByAppendingString:extra] : @"cleared") : @"";
                done(msg, success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"importAMGRecords"]) {
            NSString *dir = query[@"dir"] ?: [NDRecordStore resolvedAMGImportPath];
            NSError *err = nil;
            BOOL kc = query[@"keychain"] ? [query[@"keychain"] boolValue] : [NDConfig shared].importKeychainWithData;
            NSUInteger n = 0;
            @try {
                n = [[NDRecordStore shared] importAMGRecordsFromDirectory:dir importKeychain:kc error:&err];
            } @catch (NSException *ex) {
                NSString *detail = [NSString stringWithFormat:@"导入异常：%@ — %@\n(详见 Media/AMG/import/nd-last-import.txt)",
                                    ex.name ?: @"NSException", ex.reason ?: @"?"];
                err = [NSError errorWithDomain:@"NDRecordStore" code:99
                                     userInfo:@{NSLocalizedDescriptionKey: detail}];
            }
            NSString *names = [[[NDRecordStore shared] lastImportedRecordNames] componentsJoinedByString:@", "] ?: @"";
            NSString *holo = [[NDRecordStore shared] lastImportHoloSummary] ?: @"";
            NSString *applyMsg = @"";
            if (n > 0) {
                NSString *applyName = [[NDRecordStore shared] lastImportedRecordNames].lastObject;
                if (applyName.length) {
                    @try {
                        // Set current + restore staged Venmo/etc. into live sandboxes
                        [[NDRecordStore shared] setCurrentRecordName:applyName];
                        NSArray *bids = [[NDRecordStore shared] appBundleIdsForRecord:applyName];
                        if (!bids.count) bids = @[@"net.kortina.labs.Venmo"];
                        [[NDAppDataManager shared] terminateApps:bids];
                        NSError *rErr = nil;
                        [[NDAppDataManager shared] restoreAllStagedAppsFromRecord:applyName error:&rErr];
                        [[NDAppDataManager shared] restoreAppGroupsForRecord:applyName];
                        NSString *bind = @"";
                        if ([bids containsObject:@"net.kortina.labs.Venmo"]) {
                            bind = [[NDAppDataManager shared] bindVenmoKeychainToCurrentRecord] ?: @"";
                        }
                        NSString *rr = [NDAppDataManager shared].lastRestoreReport ?: @"";
                        // Append sandbox write proof into the same import log the user reads
                        NSString *prev = [NSString stringWithContentsOfFile:@"/var/mobile/Media/AMG/import/nd-last-import.txt"
                                                                  encoding:NSUTF8StringEncoding error:nil] ?: @"";
                        NSString *extra = [NSString stringWithFormat:@"\n--- sandbox write (Containers) ---\n%@\n--- bindVenmo ---\n%@", rr, bind];
                        [[prev stringByAppendingString:extra] writeToFile:@"/var/mobile/Media/AMG/import/nd-last-import.txt"
                                                               atomically:YES encoding:NSUTF8StringEncoding error:nil];
                        applyMsg = [NSString stringWithFormat:@"applied:%@\n%@\n%@", applyName,
                                    rr.length ? rr : (rErr.localizedDescription ?: @""), bind];
                    } @catch (NSException *ex) {
                        applyMsg = [NSString stringWithFormat:@"apply exception: %@ — %@", ex.name ?: @"?", ex.reason ?: @"?"];
                    }
                }
                body = [NSString stringWithFormat:@"%lu\n%@\nstaged:%@\n%@\n%@",
                        (unsigned long)n, holo, names, applyMsg, err.localizedDescription ?: @""];
            } else {
                body = err.localizedDescription.length
                    ? err.localizedDescription
                    : [NSString stringWithFormat:@"0\n未导入。扫描目录：%@\n见 Media/AMG/import/nd-last-import.txt", dir];
            }
            [[NDRecordStore shared] writeResultCode:(n > 0) ? 1 : 0];
            done(body, (n > 0) ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"importIGrimace"] || [fun isEqualToString:@"importAWZ"] || [fun isEqualToString:@"importAMGMedia"]) {
            NSString *kind = @"AMG";
            NSString *fallback = [NDRecordStore resolvedAMGImportPath];
            if ([fun isEqualToString:@"importIGrimace"]) {
                kind = @"iGrimace";
                fallback = [NDRecordStore iGrimaceImportPath];
            } else if ([fun isEqualToString:@"importAWZ"]) {
                kind = @"AWZ";
                fallback = [NDRecordStore awzImportPath];
            }
            NSString *dir = query[@"dir"] ?: fallback;
            NSError *err = nil;
            BOOL kc = query[@"keychain"] ? [query[@"keychain"] boolValue] : [NDConfig shared].importKeychainWithData;
            NSUInteger n = [[NDRecordStore shared] importForeignRecordsFromDirectory:dir kind:kind importKeychain:kc error:&err];
            body = [NSString stringWithFormat:@"%lu", (unsigned long)n];
            [[NDRecordStore shared] writeResultCode:(n > 0 || !err) ? 1 : 0];
            done(body, (n > 0 || !err) ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"exportAMGMedia"]) {
            NSString *dir = query[@"dir"] ?: [NDRecordStore amgTarPath];
            BOOL slim = query[@"slim"] ? [query[@"slim"] boolValue] : [NDConfig shared].slimExportStripMedia;
            NSError *err = nil;
            NSUInteger n = [[NDRecordStore shared] exportAMGRecordsToDirectory:dir slim:slim error:&err];
            body = [NSString stringWithFormat:@"%lu\n%@", (unsigned long)n, dir];
            [[NDRecordStore shared] writeResultCode:(n > 0 || !err) ? 1 : 0];
            done(body, (n > 0 || !err) ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"slimRecord"]) {
            NSString *name = query[@"recordName"] ?: [[NDRecordStore shared] currentRecordName];
            if (!name.length || [name isEqualToString:@"原始机器"]) {
                [[NDRecordStore shared] writeResultCode:0];
                done(@"no record", 400);
                return;
            }
            NSUInteger n = [[NDAppDataManager shared] slimMediaInRecord:name];
            body = [NSString stringWithFormat:@"%lu", (unsigned long)n];
            [[NDRecordStore shared] writeResultCode:1];
            done(body, 200);
            return;
        }

        [[NDRecordStore shared] writeResultCode:0];
        done(@"unknown fun", 404);
    });
}

@end
