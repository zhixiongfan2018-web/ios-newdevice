#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Extract .tar / .tar.gz / .tgz / .zip into destDir (creates destDir).
/// Uses onboard tar/unzip when present; falls back to built-in gzip+ustar reader.
BOOL NDExtractArchiveToDirectory(NSString *archivePath, NSString *destDir, NSError * _Nullable * _Nullable error);

/// Pack a directory into an uncompressed ustar `.tar`.
BOOL NDCreateTarFromDirectory(NSString *sourceDir, NSString *tarPath, NSError * _Nullable * _Nullable error);

/// Pack a directory into gzip `.tar.gz` (AMG classic exchange format).
BOOL NDCreateTarGzFromDirectory(NSString *sourceDir, NSString *tarGzPath, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
