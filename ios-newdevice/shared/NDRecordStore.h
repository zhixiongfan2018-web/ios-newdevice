#import <Foundation/Foundation.h>
#import "NDDeviceProfile.h"

NS_ASSUME_NONNULL_BEGIN

@interface NDRecordStore : NSObject

+ (instancetype)shared;

- (NSArray<NSString *> *)allRecordNames;
- (nullable NSString *)currentRecordName;
- (void)setCurrentRecordName:(nullable NSString *)name;
- (nullable NSString *)lastSessionRecordName;
- (void)clearLastSessionRecordName;
+ (BOOL)isNewDeviceUIRunning;
- (nullable NDDeviceProfile *)currentProfile;
- (nullable NDDeviceProfile *)profileNamed:(NSString *)name;

- (BOOL)saveProfile:(NDDeviceProfile *)profile error:(NSError * _Nullable * _Nullable)error;
- (BOOL)deleteRecord:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)deleteAllRecordsKeepingCurrent:(BOOL)keepCurrent error:(NSError * _Nullable * _Nullable)error;
- (BOOL)renameRecord:(NSString *)oldName to:(NSString *)newName error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setEnabled:(BOOL)enabled forRecord:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setEnabledForAll:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;

- (NDDeviceProfile *)createNewRecordAndActivate:(NSError * _Nullable * _Nullable)error;
/// Re-randomize an existing record (keep name + remark), clear staged apps, activate.
- (nullable NDDeviceProfile *)renewRecordNamed:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToOriginal:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToNext:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToPrevious:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToFirst:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToRecord:(NSString *)name error:(NSError * _Nullable * _Nullable)error;

/// Import AMG (or compatible) identity plists. Returns number imported.
- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir error:(NSError * _Nullable * _Nullable)error;
- (nullable NDDeviceProfile *)importProfileAtPath:(NSString *)path preferredName:(nullable NSString *)name error:(NSError * _Nullable * _Nullable)error;

/// Direct import of one AMG_resolved record folder (has 01_plaintext_identity / 03_holographic_backups).
/// Analysis pack only — does NOT write `/var/mobile/AMG/<record>/` (AMG ignores that layout).
- (BOOL)importAMGResolvedRecordAtPath:(NSString *)recordPath
                                 note:(NSString * _Nullable * _Nullable)outNote
                                error:(NSError * _Nullable * _Nullable)error;

/// Classic AMG record folder (faker.plist + holographic apps at root).
/// 1) Installs to `/var/mobile/AMG/<folderName>/` so AMG recognizes it
/// 2) Imports identity + holographic apps into NewDevice (Venmo-hardened)
- (BOOL)importClassicAMGRecordAtPath:(NSString *)recordPath
                                note:(NSString * _Nullable * _Nullable)outNote
                               error:(NSError * _Nullable * _Nullable)error;

/// Bundle IDs for a record's App environment (selectApp.plist + apps/ folders).
- (NSArray<NSString *> *)appBundleIdsForRecord:(NSString *)name;

/// Names imported by the most recent AMG import (for auto-activate / UI summary).
@property (nonatomic, copy, readonly) NSArray<NSString *> *lastImportedRecordNames;
/// Human-readable holographic staging summary from last import (apps + bytes).
@property (nonatomic, copy, readonly, nullable) NSString *lastImportHoloSummary;
/// Counts from the most recent import pass (success / fail / skipped-already-present).
@property (nonatomic, assign, readonly) NSUInteger lastImportSuccessCount;
@property (nonatomic, assign, readonly) NSUInteger lastImportFailCount;
@property (nonatomic, assign, readonly) NSUInteger lastImportSkipCount;
- (void)beginImportSession;
- (void)endImportSession;
/// YES if this record name already has a NewDevice profile (import should skip).
- (BOOL)recordAlreadyImported:(NSString *)name;

- (void)writeResultCode:(NSInteger)code;
- (void)notifyReload;

/// GPS/timezone follow current public IP. Identity fields are never rewritten.
/// Returns a short note when the pin actually moved, else empty.
- (nullable NSString *)refreshLocationFromCurrentIP;
/// @param force YES after airplane / switch (skip the 75s throttle).
- (nullable NSString *)refreshLocationFromCurrentIPForce:(BOOL)force;

@end

NS_ASSUME_NONNULL_END
