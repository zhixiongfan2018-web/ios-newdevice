#import "NDOperationService.h"
#import "NDRecordStore.h"
#import "NDRecordStore+ImportExport.h"
#import "NDConfig.h"
#import "NDAppDataManager.h"
#import "NDAirplane.h"
#import "NDPaths.h"
#import "NDDeviceProfile.h"

@interface NDOperationService ()
@property (nonatomic, assign) BOOL asyncBusy;
@property (nonatomic, strong) NSDate *asyncBusySince;
@end

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

- (BOOL)tryBeginAsyncJob {
    @synchronized (self) {
        if (self.asyncBusy) {
            NSTimeInterval age = self.asyncBusySince ? -[self.asyncBusySince timeIntervalSinceNow] : 9999;
            if (age < 90) return NO;
            NSLog(@"[NewDevice] clearing stale asyncBusy after %.0fs", age);
            self.asyncBusy = NO;
            self.asyncBusySince = nil;
        }
        self.asyncBusy = YES;
        self.asyncBusySince = [NSDate date];
        return YES;
    }
}

- (void)endAsyncJob {
    @synchronized (self) {
        self.asyncBusy = NO;
        self.asyncBusySince = nil;
    }
}

- (BOOL)isAsyncBusy {
    @synchronized (self) {
        return self.asyncBusy;
    }
}

+ (BOOL)isAsyncAckFun:(NSString *)fun {
    static NSSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"newRecord", @"renewRecord", @"originRecord", @"nextRecord", @"firstRecord", @"prevRecord", @"previousRecord", @"setRecord",
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
    // User-selected targets only — never permanently union every record's apps into targetApps
    // (that bloated switch/backup and slowed 一键新机).
    NSArray *targets = [NDConfig shared].targetApps ?: @[];
    if (targets.count) return targets;

    // Fallback when「目标应用」尚未配置：union of the two records (do not save).
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:current]) {
        if (b.length) [set addObject:b];
    }
    for (NSString *b in [[NDRecordStore shared] appBundleIdsForRecord:previous]) {
        if (b.length) [set addObject:b];
    }
    if (!set.count) [set addObject:@"net.kortina.labs.Venmo"];
    return set.array;
}

- (void)prepareTargets:(void (^)(NSArray<NSString *> *apps, NSString *previousRecord))block {
    [self prepareTargetsForDestination:nil block:block];
}

- (void)prepareTargetsForDestination:(NSString *)destination
                               block:(void (^)(NSArray<NSString *> *apps, NSString *previousRecord))block {
    NSString *prev = [[NDRecordStore shared] currentRecordName] ?: @"原始机器";
    NSString *dest = destination.length ? destination : prev;
    NSArray *apps = [self appsForSwitchTo:dest previous:prev];
    // Always force-quit work-set apps BEFORE identity/sandbox change so the
    // previous environment cannot stay in memory (Venmo/Safari/Kalshi...).
    NSLog(@"[NewDevice] quit targets first (%lu): %@", (unsigned long)apps.count,
          [apps componentsJoinedByString:@","]);
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
        // Make spoofed identity look like a coherent real device before sandbox work.
        if (current.length && ![current isEqualToString:@"原始机器"]) {
            NDDeviceProfile *curP = [[NDRecordStore shared] profileNamed:current];
            if (curP) {
                NSString *fix = [curP alignConsistency];
                if (fix.length) {
                    [[NDRecordStore shared] saveProfile:curP error:nil];
                    NSLog(@"[NewDevice] alignParams %@", fix);
                }
            }
        }

        // Work set = user targetApps (from prepareTargets). Do not grow targetApps here.
        if (!apps.count) {
            apps = [self appsForSwitchTo:current previous:previous];
        }

        // Close again immediately before wipe/restore (user or SpringBoard may have relaunched).
        if (apps.count) {
            NSLog(@"[NewDevice] quit targets before wipe (%lu)", (unsigned long)apps.count);
            [[NDAppDataManager shared] terminateApps:apps];
        }

        BOOL hasStaged = [self recordHasStagedApps:current];
        if (cfg.holographicBackup && apps.count) {
            BOOL sameRecord = previous.length && current.length && [previous isEqualToString:current];
            BOOL leavingReal = !sameRecord && previous.length && ![previous isEqualToString:@"原始机器"];

            // Snapshot only work-set apps when leaving a real record (fat-guard in backupApps).
            if (leavingReal) {
                [[NDAppDataManager shared] backupApps:apps toRecord:previous error:nil];
            }

            // Wipe only selected targets so other apps stay untouched.
            [[NDAppDataManager shared] clearDataForApps:apps error:nil];
            if (hasStaged && ![current isEqualToString:@"原始机器"]) {
                NSError *restoreErr = nil;
                [[NDAppDataManager shared] restoreAllStagedAppsFromRecord:current
                                                          onlyBundleIds:apps
                                                                  error:&restoreErr];
                [[NDAppDataManager shared] restoreAppGroupsForRecord:current];
                if (restoreErr) NSLog(@"[NewDevice] restore warning: %@", restoreErr.localizedDescription);
                // Strict isolation: previous Venmo Keychain must not leak into this record.
                if ([apps containsObject:@"net.kortina.labs.Venmo"]) {
                    NSString *bind = [[NDAppDataManager shared] bindVenmoKeychainToCurrentRecord];
                    NSLog(@"[NewDevice] bindVenmo %@", bind);
                }
            } else if ([apps containsObject:@"net.kortina.labs.Venmo"]) {
                // Empty 一键新机 / 原始机器: stage in-app clear for next Venmo open —
                // do not launch/bounce Venmo during the switch.
                [[NDAppDataManager shared] stageVenmoSessionClearOnly];
            }
        } else if (apps.count) {
            // holographicBackup OFF = identity-only switch. Never wipe live sandboxes
            // without a restore path (that permanently destroys target App data).
            if ([apps containsObject:@"net.kortina.labs.Venmo"]) {
                [[NDAppDataManager shared] stageVenmoSessionClearOnly];
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

        // Keep NewDevice sole inject owner for targets (exclude from amg.plist).
        [[NDAppDataManager shared] syncInjectFilterWithTargetApps:apps ?: (cfg.targetApps ?: @[])];

        // Airplane is not isolation — run async so switch ACK is not blocked.
        // After IP may change, realign GPS/timezone to the new egress IP.
        if (cfg.smartAirplane) {
            NSString *recordForGeo = [current copy];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [NDAirplane toggleAirplaneWithDelay:0.6 error:nil];
                if (!cfg.locationFromIP || !cfg.spoofLocation) return;
                if (!recordForGeo.length || [recordForGeo isEqualToString:@"原始机器"]) return;
                NSDictionary *geo = [NDAirplane fetchIPGeolocationSync];
                NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:recordForGeo];
                if (!p || !geo) return;
                NSString *note = [p applyGeolocation:geo jitter:cfg.smartLocationOffset];
                if (note.length) {
                    [p alignConsistency];
                    [[NDRecordStore shared] saveProfile:p error:nil];
                    if ([[[NDRecordStore shared] currentRecordName] isEqualToString:recordForGeo]) {
                        [[NDRecordStore shared] notifyReload];
                    }
                    NSLog(@"[NewDevice] post-switch locationFromIP %@", note);
                }
            });
        }
    } @catch (NSException *ex) {
        NSLog(@"[NewDevice] afterSwitch exception: %@", ex);
        // Never leave result stuck at 2 — identity switch already happened
    }
}

- (void)runAsync:(NSString *)fun query:(NSDictionary<NSString *,NSString *> *)query completion:(void (^)(NSString * _Nullable, NSInteger))completion {
    [self runAsync:fun query:query preclaimed:NO completion:completion];
}

- (void)runAsync:(NSString *)fun query:(NSDictionary<NSString *,NSString *> *)query preclaimed:(BOOL)preclaimed completion:(void (^)(NSString * _Nullable, NSInteger))completion {
    BOOL isAsync = [NDOperationService isAsyncAckFun:fun];
    if (isAsync && !preclaimed) {
        if (![self tryBeginAsyncJob]) {
            if (completion) completion(@"busy", 409);
            return;
        }
    }

    void (^done)(NSString *, NSInteger) = ^(NSString *body, NSInteger code) {
        // Persist body for async pollers (HTTP only ACKs "accepted").
        NSString *text = body ?: @"";
        NSArray *bodyPaths = @[
            @"/var/mobile/newdeviceResult.body.txt",
            [[NDPaths jbPrefix] stringByAppendingPathComponent:@"var/mobile/newdeviceResult.body.txt"],
            [[NDPaths mediaHomeDir] stringByAppendingPathComponent:@"newdeviceResult.body.txt"],
        ];
        for (NSString *path in bodyPaths) {
            if (!path.length) continue;
            NSString *dir = [path stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [NDPaths makePathWorldReadable:path];
        }
        if (isAsync) [self endAsyncJob];
        if (completion) completion(body, code);
    };

    dispatch_async([self mutateQueue], ^{
        if (isAsync) [[NDRecordStore shared] writeResultCode:2];
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

        if ([fun isEqualToString:@"renewRecord"]) {
            NSString *name = query[@"recordName"] ?: @"";
            if (!name.length) {
                [[NDRecordStore shared] writeResultCode:0];
                done(@"请先选中一个环境", 400);
                return;
            }
            [self prepareTargetsForDestination:name block:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                NDDeviceProfile *p = [[NDRecordStore shared] renewRecordNamed:name error:&err];
                if (!p) {
                    [[NDRecordStore shared] writeResultCode:0];
                    done(err.localizedDescription ?: @"", 500);
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
            // Restore only configured target apps (do not grow targetApps from record).
            NDConfig *cfg = [NDConfig shared];
            NSArray *bids = cfg.targetApps ?: @[];
            if (!bids.count) {
                bids = [[NDRecordStore shared] appBundleIdsForRecord:name] ?: @[];
                if (!bids.count) bids = @[ @"net.kortina.labs.Venmo" ];
            }
            [[NDAppDataManager shared] terminateApps:bids];
            NSMutableArray *lines = [NSMutableArray array];
            for (NSString *bid in bids) {
                if ([bid hasPrefix:@"."]) continue;
                if (![[NDAppDataManager shared] containerPathForBundleId:bid]) {
                    [[NDAppDataManager shared] tryLaunchAppToCreateContainer:bid];
                    [lines addObject:[NSString stringWithFormat:@"launch-try %@", bid]];
                }
            }
            NSError *err = nil;
            [[NDAppDataManager shared] restoreAllStagedAppsFromRecord:name onlyBundleIds:bids error:&err];
            [[NDAppDataManager shared] restoreAppGroupsForRecord:name];
            NSString *bind = @"";
            if ([bids containsObject:@"net.kortina.labs.Venmo"]) {
                bind = [[NDAppDataManager shared] bindVenmoKeychainToCurrentRecord] ?: @"";
            }
            NSString *probe = [[NDAppDataManager shared] probeLiveContainerForBundleId:@"net.kortina.labs.Venmo"];
            NSString *report = [NDAppDataManager shared].lastRestoreReport ?: err.localizedDescription ?: @"";
            if (lines.count) report = [NSString stringWithFormat:@"%@\n%@", [lines componentsJoinedByString:@"\n"], report];
            report = [NSString stringWithFormat:@"%@\n--- bindVenmo ---\n%@\n--- probe ---\n%@",
                      report, bind, probe ?: @""];
            [report writeToFile:@"/var/mobile/Media/NewDevice/last-restore.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            // Do not treat "liveAkc=missing" / "AppGroup FAIL" notes as a hard
            // switch failure — those are per-app keychain/group hints.
            BOOL failed = (err != nil);
            [[NDRecordStore shared] writeResultCode:failed ? 0 : 1];
            done(report, failed ? 500 : 200);
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

        if ([fun isEqualToString:@"installDeb"] || [fun isEqualToString:@"upgradeDeb"] || [fun isEqualToString:@"installNewDeviceDeb"]) {
            NSString *path = query[@"path"] ?: query[@"filePath"] ?: @"";
            body = [[NDAppDataManager shared] installDebAtPath:path] ?: @"";
            BOOL ok = [body containsString:@"OK installed"];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(body, ok ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"getTargetApps"]) {
            NSArray *targets = [NDConfig shared].targetApps ?: [NSArray array];
            body = [targets componentsJoinedByString:@"\n"];
            [[NDRecordStore shared] writeResultCode:1];
            done(body ?: @"", 200);
            return;
        }

        if ([fun isEqualToString:@"syncInjectFilter"] || [fun isEqualToString:@"syncAmgFilter"]) {
            [[NDConfig shared] reload];
            NSArray *targets = [NDConfig shared].targetApps ?: @[];
            if (!targets.count) targets = @[ @"net.kortina.labs.Venmo" ];
            body = [[NDAppDataManager shared] syncInjectFilterWithTargetApps:targets] ?: @"";
            [[NDRecordStore shared] writeResultCode:body.length ? 1 : 0];
            done(body, body.length ? 200 : 500);
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
            NSString *name = query[@"recordName"] ?: @"";
            NSString *cur = [[NDRecordStore shared] currentRecordName] ?: @"";
            // Deleting the live env must leave sandboxes (afterSwitch) before wiping the record.
            if (name.length && [name isEqualToString:cur] && ![name isEqualToString:@"原始机器"]) {
                [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                    NSError *err = nil;
                    [[NDRecordStore shared] setCurrentRecordName:@"原始机器"];
                    [self afterSwitchFrom:previousRecord to:@"原始机器" apps:apps];
                    BOOL success = [[NDRecordStore shared] deleteRecord:name error:&err];
                    [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                    done(success ? @"" : (err.localizedDescription ?: @""), success ? 200 : 500);
                }];
                return;
            }
            ok = [[NDRecordStore shared] deleteRecord:name error:&error];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(ok ? @"" : (error.localizedDescription ?: @""), ok ? 200 : 500);
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
            if (p && ![p.name isEqualToString:@"原始机器"]) {
                NSString *fix = [p alignConsistency];
                if (fix.length) {
                    [[NDRecordStore shared] saveProfile:p error:nil];
                }
            }
            NSString *savePath = query[@"saveFilePath"];
            if (p && savePath.length) {
                [p writeToPath:savePath error:&error];
            }
            body = p ? [[NSString alloc] initWithData:[NSPropertyListSerialization dataWithPropertyList:[p toDictionary] format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] encoding:NSUTF8StringEncoding] : @"";
            [[NDRecordStore shared] writeResultCode:p ? 1 : 0];
            done(body ?: @"", p ? 200 : 500);
            return;
        }

        if ([fun isEqualToString:@"alignParams"] || [fun isEqualToString:@"alignRecordParam"]) {
            NSString *name = query[@"recordName"] ?: [[NDRecordStore shared] currentRecordName];
            NDDeviceProfile *p = name.length ? [[NDRecordStore shared] profileNamed:name] : [[NDRecordStore shared] currentProfile];
            if (!p) {
                [[NDRecordStore shared] writeResultCode:0];
                done(@"no profile", 500);
                return;
            }
            NSString *fix = [p alignConsistency] ?: @"";
            ok = [[NDRecordStore shared] saveProfile:p error:&error];
            [[NDRecordStore shared] notifyReload];
            body = [NSString stringWithFormat:@"record=%@\nfixes=%@\n", p.name ?: @"?", fix.length ? fix : @"(already aligned)"];
            [[NDRecordStore shared] writeResultCode:ok ? 1 : 0];
            done(body, ok ? 200 : 500);
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
            if (!name.length) name = [[NDRecordStore shared] currentRecordName] ?: @"";
            NDDeviceProfile *p = name.length ? [[NDRecordStore shared] profileNamed:name] : nil;
            NSString *savePath = query[@"saveFilePath"];
            if (p && savePath.length) [p writeToPath:savePath error:&error];
            body = p ? [[NSString alloc] initWithData:[NSPropertyListSerialization dataWithPropertyList:[p toDictionary] format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] encoding:NSUTF8StringEncoding] : @"";
            [[NDRecordStore shared] writeResultCode:p ? 1 : 0];
            done(body.length ? body : (p ? @"" : @"no record"), p ? 200 : 500);
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
            NSString *previous = [[NDRecordStore shared] currentRecordName] ?: @"原始机器";
            ok = [[NDRecordStore shared] saveProfile:p error:&error];
            if (ok && [fun isEqualToString:@"setCurrentRecordParam"]) {
                BOOL switched = p.name.length && ![p.name isEqualToString:previous];
                if (switched) {
                    [self prepareTargetsForDestination:p.name block:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                        [[NDRecordStore shared] setCurrentRecordName:p.name];
                        [self afterSwitchFrom:previousRecord to:p.name apps:apps];
                        [[NDRecordStore shared] notifyReload];
                        [[NDRecordStore shared] writeResultCode:1];
                        done(@"ok", 200);
                    }];
                    return;
                }
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
            NSUInteger okN = [NDRecordStore shared].lastImportSuccessCount;
            NSUInteger failN = [NDRecordStore shared].lastImportFailCount;
            NSUInteger skipN = [NDRecordStore shared].lastImportSkipCount;
            if (okN == 0 && n > 0) okN = n;
            NSString *applyMsg = @"";
            if (n > 0) {
                // Stage only — do NOT auto-restore into live sandboxes (jetsam + UI says restore separately).
                NSString *applyName = [[NDRecordStore shared] lastImportedRecordNames].lastObject;
                if (applyName.length) {
                    [[NDRecordStore shared] setCurrentRecordName:applyName];
                    applyMsg = [NSString stringWithFormat:@"staged:%@ (tap record to apply)", applyName];
                }
            }
            // Compact body for UI: success / fail / skip
            body = [NSString stringWithFormat:@"ok=%lu fail=%lu skip=%lu",
                    (unsigned long)okN, (unsigned long)failN, (unsigned long)skipN];
            if (names.length) body = [body stringByAppendingFormat:@"\n%@", names];
            if (applyMsg.length) body = [body stringByAppendingFormat:@"\n%@", applyMsg];
            if (err.localizedDescription.length && n == 0 && skipN == 0) {
                body = err.localizedDescription;
            }
            BOOL anyOk = (okN > 0) || (skipN > 0 && failN == 0);
            [[NDRecordStore shared] writeResultCode:anyOk || n > 0 ? 1 : 0];
            done(body, (okN > 0 || skipN > 0) ? 200 : 500);
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
            NSString *dir = query[@"dir"] ?: [NDPaths mediaExportDir];
            BOOL slim = query[@"slim"] ? [query[@"slim"] boolValue] : [NDConfig shared].slimExportStripMedia;
            NSError *err = nil;
            NSUInteger n = 0;
            NSString *namesCSV = query[@"recordNames"] ?: query[@"names"] ?: @"";
            if (namesCSV.length) {
                NSMutableArray *picked = [NSMutableArray array];
                for (NSString *part in [namesCSV componentsSeparatedByString:@","]) {
                    NSString *n = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (n.length) [picked addObject:n];
                }
                n = [[NDRecordStore shared] exportRecordsNamed:picked toDirectory:dir slim:slim error:&err];
            } else {
                n = [[NDRecordStore shared] exportAMGRecordsToDirectory:dir slim:slim error:&err];
            }
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
