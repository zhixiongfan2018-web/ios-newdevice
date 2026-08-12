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
            @"exportAMGMedia", @"slimRecord",
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

- (void)afterSwitchFrom:(NSString *)previous to:(NSString *)current apps:(NSArray<NSString *> *)apps {
    NDConfig *cfg = [NDConfig shared];
    // Prefer apps belonging to the destination record (imported selectApp / apps/)
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:apps ?: @[]];
    for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:current]) [set addObject:b];
    for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:previous]) [set addObject:b];
    apps = set.array;
    if (apps.count) {
        cfg.targetApps = apps;
        [cfg save];
    }
    if (cfg.holographicBackup && apps.count) {
        // CRITICAL: never backup when re-selecting the same record — that overwrites
        // freshly imported holographic trees (e.g. Venmo 22MB) with empty live sandboxes.
        BOOL sameRecord = previous.length && current.length && [previous isEqualToString:current];
        if (!sameRecord && previous.length && ![previous isEqualToString:@"原始机器"]) {
            [[NDAppDataManager shared] backupApps:apps toRecord:previous error:nil];
        }
        if ([current isEqualToString:@"原始机器"]) {
            [[NDAppDataManager shared] clearDataForApps:apps error:nil];
        } else {
            NSError *restoreErr = nil;
            [[NDAppDataManager shared] restoreApps:apps fromRecord:current error:&restoreErr];
            [[NDAppDataManager shared] restoreAppGroupsForRecord:current];
            if (restoreErr) {
                NSLog(@"[NewDevice] restore warning: %@", restoreErr.localizedDescription);
            }
        }
    } else if (apps.count) {
        [[NDAppDataManager shared] clearDataForApps:apps error:nil];
    }

    // AMG-style pasteboard holographic: always snapshot outgoing record when enabled
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
}

- (void)runAsync:(NSString *)fun query:(NSDictionary<NSString *,NSString *> *)query completion:(void (^)(NSString * _Nullable, NSInteger))completion {
    void (^done)(NSString *, NSInteger) = ^(NSString *body, NSInteger code) {
        if (completion) completion(body, code);
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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
                if (success) [self afterSwitchFrom:previousRecord to:name apps:apps];
                NSString *msg = name;
                if (success) {
                    NSArray *bids = [[NDRecordStore shared] appBundleIdsForRecord:name];
                    NSMutableArray *missing = [NSMutableArray array];
                    for (NSString *b in bids) {
                        NSString *backup = [NDPaths appsBackupDirForRecord:name bundleId:b];
                        BOOL has = [[NSFileManager defaultManager] fileExistsAtPath:backup];
                        if (has && ![[NDAppDataManager shared] containerPathForBundleId:b]) [missing addObject:b];
                    }
                    if (missing.count) {
                        msg = [NSString stringWithFormat:@"%@\n未安装无法写入: %@", name, [missing componentsJoinedByString:@", "]];
                    }
                } else {
                    msg = err.localizedDescription ?: name;
                }
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(msg, success ? 200 : 500);
            }];
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
            NDDeviceProfile *p = [NDDeviceProfile profileAtPath:filePath];
            if (!p) {
                [[NDRecordStore shared] writeResultCode:0];
                done(@"", 500);
                return;
            }
            if (name.length) p.name = name;
            ok = [[NDRecordStore shared] saveProfile:p error:&error];
            if (ok && [fun isEqualToString:@"setCurrentRecordParam"]) {
                [[NDRecordStore shared] setCurrentRecordName:p.name];
                [[NDRecordStore shared] notifyReload];
            }
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(@"", ok ? 200 : 500);
            return;
        }

        // AMG-style: clear target apps without generating a new identity
        if ([fun isEqualToString:@"clearAppData"] || [fun isEqualToString:@"cleanApps"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                (void)previousRecord;
                NSError *err = nil;
                BOOL success = [[NDAppDataManager shared] clearDataForApps:apps error:&err];
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(success ? @"cleared" : @"", success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"importAMGRecords"]) {
            NSString *dir = query[@"dir"] ?: [NDRecordStore resolvedAMGImportPath];
            NSError *err = nil;
            BOOL kc = query[@"keychain"] ? [query[@"keychain"] boolValue] : [NDConfig shared].importKeychainWithData;
            NSUInteger n = [[NDRecordStore shared] importAMGRecordsFromDirectory:dir importKeychain:kc error:&err];
            // Auto-apply last imported record so Venmo/etc. land in live sandboxes immediately
            NSString *applyName = [[NDRecordStore shared] lastImportedRecordNames].lastObject;
            if (n > 0 && applyName.length) {
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                __block NSString *applyMsg = @"";
                [self prepareTargetsForDestination:applyName block:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                    NSError *swErr = nil;
                    if ([[NDRecordStore shared] switchToRecord:applyName error:&swErr]) {
                        [self afterSwitchFrom:previousRecord to:applyName apps:apps];
                        applyMsg = [NSString stringWithFormat:@"applied:%@", applyName];
                    } else {
                        applyMsg = swErr.localizedDescription ?: @"apply failed";
                    }
                    dispatch_semaphore_signal(sem);
                }];
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)));
                body = [NSString stringWithFormat:@"%lu\n%@\n%@\n%@", (unsigned long)n,
                        [[NDRecordStore shared] lastImportHoloSummary] ?: @"",
                        applyMsg,
                        err.localizedDescription ?: @""];
            } else {
                body = [NSString stringWithFormat:@"%lu", (unsigned long)n];
            }
            [[NDRecordStore shared] writeResultCode:(n > 0 || !err) ? 1 : 0];
            done(body, (n > 0 || !err) ? 200 : 500);
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
