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

/// Restore every staged app under Records/<name>/apps/ (source of truth after AMG import).
- (BOOL)restoreAllStagedAppsFromRecord:(NSString *)recordName error:(NSError * _Nullable * _Nullable)error;

/// Human-readable report from the last restore (also written to Media/NewDevice/last-restore.txt).
@property (nonatomic, copy, readonly, nullable) NSString *lastRestoreReport;

/// Import AMG holographic trees (bundleId/Documents|Library + AppGroup) into a NewDevice record.
- (void)importAMGHolographicFromDirectory:(NSString *)amgRecordDir intoRecord:(NSString *)recordName;

/// Restore App Group containers previously imported/backed up under Records/<name>/AppGroup.
- (BOOL)restoreAppGroupsForRecord:(NSString *)recordName;

/// Pasteboard holographic: backup current general pasteboard into record, restore from record.
- (void)backupPasteboardToRecord:(NSString *)recordName;
- (void)restorePasteboardFromRecord:(NSString *)recordName;
- (void)clearGeneralPasteboard;

/// Best-effort Keychain export/import (generic + internet passwords, access groups).
/// Writes `keychain-full.plist` (+ legacy `keychain-hints.plist`).
/// Also recognizes AMG `akc.plist` (Documents/akc.plist) and converts it on import/restore.
- (BOOL)backupKeychainHintsForApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName;
/// Restores Keychain dumps; returns a short stats string (items/added/failed) for reports.
- (NSString *)restoreKeychainHintsForApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName;

/// Strip image/video files under a holographic apps backup (AMG 瘦身).
- (NSUInteger)slimMediaInRecord:(NSString *)recordName;
- (NSUInteger)slimMediaInDirectory:(NSString *)root;

- (nullable NSString *)containerPathForBundleId:(NSString *)bundleId;

/// Filza-less live sandbox probe (markers, sizes, in-app akc report).
- (NSString *)probeLiveContainerForBundleId:(NSString *)bundleId;

/// Diagnose whether NewDevice.dylib is installed / injectable (ElleKit paths + markers + keychain readback).
- (NSString *)probeTweakInjection;

/// Delete Keychain items ONLY inside the app's TEAMID.bundleId access group (never scan globally).
- (NSString *)clearKeychainAccessGroupForBundleId:(NSString *)bundleId;

/// Venmo may have items under App Store team, sideload team, or no agrp — wipe known groups.
/// On iOS 18 this also opens Venmo once so in-app SecItemDelete can remove session tokens
/// that survive uninstall (daemon/App cannot see Venmo's keychain partition).
- (NSString *)clearVenmoKeychainAllKnownGroups;

/// Stage pending-clear-kc, launch Venmo briefly, wait for in-app clear marker, wipe sandbox again.
- (NSString *)purgeVenmoSessionInApp;

/// After restoring a record's Venmo files: wipe previous Keychain session then apply this record's akc.
/// Launches Venmo suspended (or briefly then returns to NewDevice) so the old account UI is not shown.
- (NSString *)bindVenmoKeychainToCurrentRecord;

/// Rename NewDevice.dylib out of inject paths so apps stop loading it (emergency recovery).
- (NSString *)setTweakInjectionEnabled:(BOOL)enabled;

/// Remove ElleKit `/var/mobile/.eksafemode` (and known mirrors) so tweaks inject again.
- (NSString *)clearElleKitSafeMode;

/// killall SpringBoard (userspace respring).
- (NSString *)respringSpringBoard;

/// Best-effort: open app once so iOS creates its data container (restoreHolo only).
- (void)tryLaunchAppToCreateContainer:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END
