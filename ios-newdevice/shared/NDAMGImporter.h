#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDAMGImporter : NSObject

/// Import one unpacked AMG record directory into NewDevice Records (does not auto-activate).
+ (BOOL)importFromAMGRecordDirectory:(NSString *)dir error:(NSError * _Nullable * _Nullable)error;

/// Scan AMG_tar (or similar) for .tar/.tar.gz/.tgz or already-extracted record folders; also accepts /var/mobile/AMG.
+ (BOOL)importFromAMGTarDirectory:(NSString *)amgTarRoot error:(NSError * _Nullable * _Nullable)error;

/// Import a single tar file or a single record directory. Optional recordName overrides folder name for tar payloads.
+ (BOOL)importFromPath:(NSString *)path
            recordName:(nullable NSString *)recordName
                 error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
