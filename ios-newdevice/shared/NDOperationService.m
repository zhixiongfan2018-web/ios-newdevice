#import "NDOperationService.h"
#import "NDRecordStore.h"
#import "NDConfig.h"
#import "NDAppDataManager.h"
#import "NDAirplane.h"
#import "NDPaths.h"
#import "NDDeviceProfile.h"

@interface NDOperationService ()
@property (nonatomic, strong) dispatch_queue_t opQueue;
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

- (instancetype)init {
    self = [super init];
    if (self) {
        // Serialize all record mutations so concurrent HTTP clients cannot interleave backups.
        _opQueue = dispatch_queue_create("com.local.newdevice.ops", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (BOOL)isAsyncAckFun:(NSString *)fun {
    static NSSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"newRecord", @"originRecord", @"nextRecord", @"firstRecord", @"setRecord",
            @"deleteRecord", @"deleteAllRecords",
            @"disableRecord", @"enableRecord", @"disableAllRecord", @"enableAllRecord",
            @"setRecordName", @"setCurrentRecordParam", @"setRecordParam",
        ]];
    });
    return fun.length && [set containsObject:fun];
}

- (void)prepareTargets:(void (^)(NSArray<NSString *> *apps, NSString *previousRecord))block {
    [[NDConfig shared] reload];
    NSArray *apps = [NDConfig shared].targetApps ?: @[];
    NSString *prev = [[NDRecordStore shared] currentRecordName] ?: @"原始机器";
    [[NDAppDataManager shared] terminateApps:apps];
    block(apps, prev);
}

/// Returns YES when switch data pipeline completed (or was intentionally skipped).
- (BOOL)afterSwitchFrom:(NSString *)previous to:(NSString *)current apps:(NSArray<NSString *> *)apps error:(NSError **)error {
    if (!current.length) {
        if (error) *error = [NSError errorWithDomain:@"NDOperation" code:10 userInfo:@{NSLocalizedDescriptionKey: @"Empty current record"}];
        return NO;
    }
    // Same-record switch must not wipe / re-backup target sandboxes.
    if (previous.length && [previous isEqualToString:current]) {
        return YES;
    }

    NDConfig *cfg = [NDConfig shared];
    NSError *pipelineError = nil;
    if (cfg.holographicBackup && apps.count) {
        if (previous.length && ![previous isEqualToString:@"原始机器"]) {
            NSError *err = nil;
            [[NDAppDataManager shared] backupApps:apps toRecord:previous error:&err];
            if (err) pipelineError = err;
        }
        if ([current isEqualToString:@"原始机器"]) {
            NSError *err = nil;
            if (![[NDAppDataManager shared] clearDataForApps:apps error:&err] && err) {
                pipelineError = err;
            }
        } else {
            NSError *err = nil;
            [[NDAppDataManager shared] restoreApps:apps fromRecord:current error:&err];
            if (err) pipelineError = err;
        }
    } else if (apps.count) {
        NSError *err = nil;
        if (![[NDAppDataManager shared] clearDataForApps:apps error:&err] && err) {
            pipelineError = err;
        }
    }
    if (cfg.smartAirplane) {
        NSError *airErr = nil;
        if (![NDAirplane toggleAirplaneWithDelay:3.0 error:&airErr] && airErr) {
            // Airplane is best-effort; do not fail the whole new-device chain.
            NSLog(@"[NewDevice] airplane toggle failed: %@", airErr);
        }
    }
    if (pipelineError && error) *error = pipelineError;
    // Holographic IO errors are logged via error out-param but do not fail identity switch.
    return YES;
}

- (void)runAsync:(NSString *)fun query:(NSDictionary<NSString *,NSString *> *)query completion:(void (^)(NSString * _Nullable, NSInteger))completion {
    void (^done)(NSString *, NSInteger) = ^(NSString *body, NSInteger code) {
        if (completion) completion(body, code);
    };

    dispatch_async(self.opQueue, ^{
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
                [self afterSwitchFrom:previousRecord to:p.name apps:apps error:nil];
                [[NDRecordStore shared] writeResultCode:1];
                done(p.name, 200);
            }];
            return;
        }

        if ([fun isEqualToString:@"originRecord"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] switchToOriginal:&err];
                if (success) [self afterSwitchFrom:previousRecord to:@"原始机器" apps:apps error:nil];
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
                if (success) [self afterSwitchFrom:previousRecord to:cur apps:apps error:nil];
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
                if (success) [self afterSwitchFrom:previousRecord to:cur apps:apps error:nil];
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(cur, success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"setRecord"]) {
            NSString *name = query[@"recordName"] ?: @"";
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] switchToRecord:name error:&err];
                if (success) [self afterSwitchFrom:previousRecord to:name apps:apps error:nil];
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(name, success ? 200 : 500);
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
            NSString *name = query[@"recordName"] ?: @"";
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL wasCurrent = previousRecord.length && [previousRecord isEqualToString:name];
                BOOL success = [[NDRecordStore shared] deleteRecord:name error:&err];
                if (success && wasCurrent) {
                    // Pointer already flipped to 原始机器 inside store; run data pipeline.
                    [self afterSwitchFrom:previousRecord to:@"原始机器" apps:apps error:nil];
                }
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(@"", success ? 200 : 500);
            }];
            return;
        }

        if ([fun isEqualToString:@"deleteAllRecords"]) {
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] deleteAllRecordsKeepingCurrent:YES error:&err];
                // keepCurrent=YES: identity unchanged → skip afterSwitch.
                (void)apps;
                (void)previousRecord;
                [[NDRecordStore shared] writeResultCode:success ? 1 : 0];
                done(@"", success ? 200 : 500);
            }];
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

        if ([fun isEqualToString:@"getRecordParam"]) {
            NSString *name = query[@"recordName"] ?: @"";
            NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
            NSString *savePath = query[@"saveFilePath"];
            if (p && savePath.length) [p writeToPath:savePath error:&error];
            [[NDRecordStore shared] writeResultCode:p ? 1 : 0];
            done(name, p ? 200 : 500);
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

        [[NDRecordStore shared] writeResultCode:0];
        done(@"unknown fun", 404);
    });
}

@end
