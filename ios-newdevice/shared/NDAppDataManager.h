#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDAppDataManager : NSObject

+ (instancetype)shared;

/// Kill target apps by bundle id.
- (void)terminateApps:(NSArray<NSString *> *)bundleIds;

/// Clear sandbox data for apps (Documents/Library/tmp under container).
- (BOOL)clearDataForApps:(NSArray<NSString *> *)bundleIds error:(NSError * _Nullable * _Nullable)error;

/// Backup app sandboxes into record folder.
- (BOOL)backupApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName error:(NSError * _Nullable * _Nullable)error;

/// Restore app sandboxes from record folder.
- (BOOL)restoreApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName error:(NSError * _Nullable * _Nullable)error;

/// Import AMG holographic trees (bundleId/Documents|Library + AppGroup) into a NewDevice record.
- (void)importAMGHolographicFromDirectory:(NSString *)amgRecordDir intoRecord:(NSString *)recordName;

/// Restore App Group containers previously imported/backed up under Records/<name>/AppGroup.
- (BOOL)restoreAppGroupsForRecord:(NSString *)recordName;

/// Best-effort Keychain export/import for given access groups (plist under backup).
- (BOOL)backupKeychainHintsForApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName;
- (BOOL)restoreKeychainHintsForApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName;

- (nullable NSString *)containerPathForBundleId:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END
