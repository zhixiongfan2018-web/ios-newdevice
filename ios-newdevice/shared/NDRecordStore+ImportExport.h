#import <Foundation/Foundation.h>
#import "NDRecordStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface NDRecordStore (ImportExport)

/// Official AMG import/export root (docs: /var/mobile/AMG_tar).
+ (NSString *)amgTarPath;
/// Some AMG builds show Media paths in UI; kept as fallbacks.
+ (NSString *)amgMediaImportPath;
+ (NSString *)amgMediaExportPath;
+ (NSString *)iGrimaceImportPath;
+ (NSString *)awzImportPath;

/// First existing among AMG_tar → Media/AMG/import → /var/mobile/AMG.
+ (NSString *)resolvedAMGImportPath;

/// Import AMG-compatible tree / AMG_tar archives. Optionally restore Keychain.
- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir
                              importKeychain:(BOOL)importKeychain
                                       error:(NSError * _Nullable * _Nullable)error;

/// Import iGrimace / AWZ style dumps (folder of plists + optional app trees).
- (NSUInteger)importForeignRecordsFromDirectory:(NSString *)dir
                                           kind:(NSString *)kind
                                  importKeychain:(BOOL)importKeychain
                                           error:(NSError * _Nullable * _Nullable)error;

/// Export records into AMG_tar / Media export (plaintext faker — no AMG runtime key needed to re-import).
/// Exports all records when `names` is nil/empty.
- (NSUInteger)exportAMGRecordsToDirectory:(NSString *)dir
                                     slim:(BOOL)slim
                                    error:(NSError * _Nullable * _Nullable)error;

/// Export selected NewDevice environments (after AMG import these are native records with apps/).
/// Pass nil/empty `names` to export every record.
- (NSUInteger)exportRecordsNamed:(NSArray<NSString *> * _Nullable)names
                     toDirectory:(NSString *)dir
                            slim:(BOOL)slim
                           error:(NSError * _Nullable * _Nullable)error;

/// Strip images/videos from a record's holographic apps backup.
- (BOOL)slimRecord:(NSString *)name error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
