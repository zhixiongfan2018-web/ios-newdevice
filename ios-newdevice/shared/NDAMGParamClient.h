#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Fetch AMG-runtime plaintext identity via official local HTTP API
/// (`getRecordParam` / `getCurrentRecordParam` on 127.0.0.1:8080),
/// or load sidecar plaintext plists next to an encrypted `faker.plist`.
/// Does NOT reverse AES — uses AMG's own decrypt-export interface.
@interface NDAMGParamClient : NSObject

/// Sidecar filenames checked before/with API (in record folder).
+ (NSArray<NSString *> *)sidecarPlaintextFileNames;

/// Relative paths under a record / resolved-extract tree (incl. 01_plaintext_identity/).
+ (NSArray<NSString *> *)sidecarPlaintextRelativePaths;

/// Load plist or JSON dict from path; nil if missing/unusable.
+ (nullable NSDictionary *)dictionaryAtPath:(NSString *)path;

/// Load first usable plaintext dict from sidecars under `recordDir`.
+ (nullable NSDictionary *)plaintextParamFromSidecarsInDirectory:(NSString *)recordDir
                                                     sourcePath:(NSString * _Nullable * _Nullable)outPath;

/// GET /cmd?fun=getRecordParam for a specific AMG record title (no current-param fallback).
/// Writes saveFilePath when provided by server; also returns parsed dict.
/// `recordName` is required (may contain + / spaces).
+ (nullable NSDictionary *)fetchPlaintextParamForRecordName:(NSString *)recordName
                                              saveFilePath:(nullable NSString *)saveFilePath
                                                     error:(NSError * _Nullable * _Nullable)error;

/// Convenience for import: sidecars first, then HTTP API; on success may write
/// `faker_plaintext.plist` into `recordDir`.
+ (nullable NSDictionary *)resolvePlaintextParamForAMGRecordDir:(NSString *)recordDir
                                                   recordTitle:(NSString *)recordTitle
                                                    sourceNote:(NSString * _Nullable * _Nullable)outNote;

/// YES if 127.0.0.1:8080 looks like NewDevice (not stock AMG).
+ (BOOL)localAPIIsNewDevice;

@end

NS_ASSUME_NONNULL_END
