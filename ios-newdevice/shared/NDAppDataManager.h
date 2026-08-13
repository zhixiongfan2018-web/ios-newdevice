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

/// Restore app sandboxes from record folder (Documents/Library/tmp + AppGroup + akc Keychain).
- (BOOL)restoreApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName error:(NSError * _Nullable * _Nullable)error;

/// AMG-style Documents/akc.plist → SecItem restore (per-app Keychain snapshot).
- (NSInteger)restoreAKCPlistAtPath:(NSString *)path;

/// Best-effort Keychain export/import for given access groups (plist under backup).
- (BOOL)backupKeychainHintsForApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName;
- (BOOL)restoreKeychainHintsForApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName;

- (nullable NSString *)containerPathForBundleId:(NSString *)bundleId;
- (nullable NSString *)sharedContainerPathForGroupId:(NSString *)groupId;

@end

NS_ASSUME_NONNULL_END
