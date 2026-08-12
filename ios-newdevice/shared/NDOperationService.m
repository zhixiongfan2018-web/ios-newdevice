#import "NDOperationService.h"
#import "NDRecordStore.h"
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
            @"clearAppData", @"cleanApps",
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

- (void)afterSwitchFrom:(NSString *)previous to:(NSString *)current apps:(NSArray<NSString *> *)apps {
    NDConfig *cfg = [NDConfig shared];
    if (cfg.holographicBackup && apps.count) {
        if (previous.length && ![previous isEqualToString:@"原始机器"]) {
            [[NDAppDataManager shared] backupApps:apps toRecord:previous error:nil];
        }
        if ([current isEqualToString:@"原始机器"]) {
            [[NDAppDataManager shared] clearDataForApps:apps error:nil];
        } else {
            [[NDAppDataManager shared] restoreApps:apps fromRecord:current error:nil];
        }
    } else if (apps.count) {
        [[NDAppDataManager shared] clearDataForApps:apps error:nil];
    }
    if (cfg.clearPasteboardOnSwitch) {
        Class PB = NSClassFromString(@"UIPasteboard");
        if (PB && [PB respondsToSelector:NSSelectorFromString(@"generalPasteboard")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id board = [PB performSelector:NSSelectorFromString(@"generalPasteboard")];
#pragma clang diagnostic pop
            if (board && [board respondsToSelector:NSSelectorFromString(@"setItems:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [board performSelector:NSSelectorFromString(@"setItems:") withObject:@[]];
#pragma clang diagnostic pop
            }
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
            [self prepareTargets:^(NSArray<NSString *> *apps, NSString *previousRecord) {
                NSError *err = nil;
                BOOL success = [[NDRecordStore shared] switchToRecord:name error:&err];
                if (success) [self afterSwitchFrom:previousRecord to:name apps:apps];
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

        [[NDRecordStore shared] writeResultCode:0];
        done(@"unknown fun", 404);
    });
}

@end
