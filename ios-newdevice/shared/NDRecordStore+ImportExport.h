#import <Foundation/Foundation.h>
#import "NDDeviceProfile.h"

NS_ASSUME_NONNULL_BEGIN

@interface NDRecordStore (ImportExport)

/// Default AMG Media paths (match AMG UI).
+ (NSString *)amgMediaImportPath;
+ (NSString *)amgMediaExportPath;
+ (NSString *)iGrimaceImportPath;
+ (NSString *)awzImportPath;

/// Import AMG-compatible tree. Optionally restore Keychain from holographic dumps.
- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir
                              importKeychain:(BOOL)importKeychain
                                       error:(NSError * _Nullable * _Nullable)error;

/// Import iGrimace / AWZ style dumps (folder of plists + optional app trees).
- (NSUInteger)importForeignRecordsFromDirectory:(NSString *)dir
                                           kind:(NSString *)kind
                                  importKeychain:(BOOL)importKeychain
                                           error:(NSError * _Nullable * _Nullable)error;

/// Export current (or all) records into AMG Media export folder.
- (NSUInteger)exportAMGRecordsToDirectory:(NSString *)dir
                                     slim:(BOOL)slim
                                    error:(NSError * _Nullable * _Nullable)error;

/// Strip images/videos from a record's holographic apps backup.
- (BOOL)slimRecord:(NSString *)name error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
