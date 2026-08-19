#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDAppDataManager : NSObject

+ (instancetype)shared;

/// Force-quit target apps (FrontBoard + SIGKILL) and wait until they are gone.
- (void)terminateApps:(NSArray<NSString *> *)bundleIds;

/// Clear sandbox data for apps (Documents/Library/tmp under container).
- (BOOL)clearDataForApps:(NSArray<NSString *> *)bundleIds error:(NSError * _Nullable * _Nullable)error;

/// Backup app sandboxes into record folder.
- (BOOL)backupApps:(NSArray<NSString *> *)bundleIds toRecord:(NSString *)recordName error:(NSError * _Nullable * _Nullable)error;

/// Restore app sandboxes from record folder.
- (BOOL)restoreApps:(NSArray<NSString *> *)bundleIds fromRecord:(NSString *)recordName error:(NSError * _Nullable * _Nullable)error;

/// Restore every staged app under Records/<name>/apps/ (source of truth after AMG import).
- (BOOL)restoreAllStagedAppsFromRecord:(NSString *)recordName error:(NSError * _Nullable * _Nullable)error;

/// Same as restoreAll, but only bundles in `only` (nil/empty = all staged). Speeds multi-target switches.
- (BOOL)restoreAllStagedAppsFromRecord:(NSString *)recordName
                        onlyBundleIds:(NSArray<NSString *> * _Nullable)only
                                error:(NSError * _Nullable * _Nullable)error;

/// Rewrite NewDevice.plist Filter.Bundles = SpringBoard + targetApps.
/// Coexist with AMG: scope amg.plist Bundles from AMG selectApp minus ND targets (never disable amg.dylib).
- (NSString *)syncInjectFilterWithTargetApps:(NSArray<NSString *> *)bundleIds;

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
/// AMG-style export slim: drop Caches / WebKit / tmp (+ optional media).
- (NSUInteger)slimAMGExportInDirectory:(NSString *)root stripMedia:(BOOL)stripMedia;

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

/// Stage pending-clear-kc without launching Venmo (for 一键新机 — no open/close flash).
- (NSString *)stageVenmoSessionClearOnly;

/// After restoring a record's Venmo files: wipe previous Keychain session then apply this record's akc.
/// Launches Venmo only for explicit purge/bind tools — switch/一键新机 must not open apps.
- (NSString *)bindVenmoKeychainToCurrentRecord;
/// Stage pending-clear + akc for this record. Does not launch Venmo (switch / 一键新机).
- (NSString *)stageVenmoKeychainBindWithoutLaunch;

/// Rename NewDevice.dylib out of inject paths so apps stop loading it (emergency recovery).
- (NSString *)setTweakInjectionEnabled:(BOOL)enabled;

/// Remove ElleKit `/var/mobile/.eksafemode` (and known mirrors) so tweaks inject again.
- (NSString *)clearElleKitSafeMode;

/// killall SpringBoard (userspace respring).
- (NSString *)respringSpringBoard;

/// Install a local .deb (Media/CrashReporter path). Tries dpkg / apt / jbctl as available.
- (NSString *)installDebAtPath:(NSString *)path;

/// Best-effort: open app once so iOS creates its data container (restoreHolo only).
- (void)tryLaunchAppToCreateContainer:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END
