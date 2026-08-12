#import <Foundation/Foundation.h>
#import "NDDeviceProfile.h"

NS_ASSUME_NONNULL_BEGIN

@interface NDRecordStore : NSObject

+ (instancetype)shared;

- (NSArray<NSString *> *)allRecordNames;
- (nullable NSString *)currentRecordName;
- (void)setCurrentRecordName:(nullable NSString *)name;
- (nullable NDDeviceProfile *)currentProfile;
- (nullable NDDeviceProfile *)profileNamed:(NSString *)name;

- (BOOL)saveProfile:(NDDeviceProfile *)profile error:(NSError * _Nullable * _Nullable)error;
- (BOOL)deleteRecord:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)deleteAllRecordsKeepingCurrent:(BOOL)keepCurrent error:(NSError * _Nullable * _Nullable)error;
- (BOOL)renameRecord:(NSString *)oldName to:(NSString *)newName error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setEnabled:(BOOL)enabled forRecord:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setEnabledForAll:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;

- (NDDeviceProfile *)createNewRecordAndActivate:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToOriginal:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToNext:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToPrevious:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToFirst:(NSError * _Nullable * _Nullable)error;
- (BOOL)switchToRecord:(NSString *)name error:(NSError * _Nullable * _Nullable)error;

/// Import AMG (or compatible) identity plists. Returns number imported.
- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir error:(NSError * _Nullable * _Nullable)error;
- (nullable NDDeviceProfile *)importProfileAtPath:(NSString *)path preferredName:(nullable NSString *)name error:(NSError * _Nullable * _Nullable)error;

/// Bundle IDs for a record's App environment (selectApp.plist + apps/ folders).
- (NSArray<NSString *> *)appBundleIdsForRecord:(NSString *)name;

- (void)writeResultCode:(NSInteger)code;
- (void)notifyReload;

@end

NS_ASSUME_NONNULL_END
