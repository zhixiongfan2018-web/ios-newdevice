#import "NDArchiveExtract.h"
#import <spawn.h>
#import <sys/wait.h>
#import <zlib.h>
#import <string.h>
#import <stdio.h>
#import <time.h>

extern char **environ;

static BOOL NDSpawn(const char *path, char *const argv[]) {
    pid_t pid = 0;
    if (posix_spawn(&pid, path, NULL, NULL, argv, environ) != 0) return NO;
    if (pid <= 0) return NO;
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static BOOL NDSpawnShell(NSString *command) {
    const char *shells[] = {
        "/var/jb/bin/sh", "/var/jb/usr/bin/sh", "/bin/sh", "/usr/bin/sh", NULL
    };
    NSFileManager *fm = [NSFileManager defaultManager];
    for (const char **s = shells; *s; s++) {
        if (![fm fileExistsAtPath:[NSString stringWithUTF8String:*s]]) continue;
        char *argv[] = { (char *)*s, "-c", (char *)command.UTF8String, NULL };
        if (NDSpawn(*s, argv)) return YES;
    }
    return NO;
}

static NSData *NDGunzipData(NSData *gz, NSError **error) {
    if (gz.length < 10) {
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:1 userInfo:@{NSLocalizedDescriptionKey: @"gzip 数据太短"}];
        return nil;
    }
    const Bytef *src = gz.bytes;
    if (!(src[0] == 0x1f && src[1] == 0x8b)) {
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:2 userInfo:@{NSLocalizedDescriptionKey: @"不是 gzip 格式"}];
        return nil;
    }
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // windowBits 15+16 = gzip
    if (inflateInit2(&strm, 15 + 16) != Z_OK) {
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:3 userInfo:@{NSLocalizedDescriptionKey: @"inflateInit 失败"}];
        return nil;
    }
    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)gz.length;
    NSMutableData *out = [NSMutableData dataWithLength:gz.length * 4 + 64 * 1024];
    int ret = Z_OK;
    while (ret == Z_OK) {
        if (strm.total_out >= out.length) {
            [out increaseLengthBy:out.length]; // grow
        }
        strm.next_out = (Bytef *)out.mutableBytes + strm.total_out;
        strm.avail_out = (uInt)(out.length - strm.total_out);
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret == Z_STREAM_END) break;
        if (ret != Z_OK) {
            inflateEnd(&strm);
            if (error) *error = [NSError errorWithDomain:@"NDArchive" code:4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"gzip 解压失败 (%d)", ret]}];
            return nil;
        }
    }
    inflateEnd(&strm);
    out.length = strm.total_out;
    return out;
}

#pragma pack(push, 1)
typedef struct {
    char name[100];
    char mode[8];
    char uid[8];
    char gid[8];
    char size[12];
    char mtime[12];
    char chksum[8];
    char typeflag;
    char linkname[100];
    char magic[6];
    char version[2];
    char uname[32];
    char gname[32];
    char devmajor[8];
    char devminor[8];
    char prefix[155];
    char pad[12];
} NDTarHeader;
#pragma pack(pop)

static unsigned long long NDTarOctal(const char *s, size_t n) {
    unsigned long long v = 0;
    for (size_t i = 0; i < n && s[i]; i++) {
        char c = s[i];
        if (c == ' ' || c == '\0') continue;
        if (c < '0' || c > '7') break;
        v = (v << 3) + (unsigned long long)(c - '0');
    }
    return v;
}

static BOOL NDExtractTarBytes(NSData *tar, NSString *destDir, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    const uint8_t *bytes = tar.bytes;
    NSUInteger len = tar.length;
    NSUInteger off = 0;
    NSUInteger written = 0;
    while (off + 512 <= len) {
        const NDTarHeader *h = (const NDTarHeader *)(bytes + off);
        off += 512;
        // two zero blocks = EOF
        BOOL allZero = YES;
        for (int i = 0; i < 512; i++) {
            if (((const uint8_t *)h)[i] != 0) { allZero = NO; break; }
        }
        if (allZero) break;

        NSString *name = [[NSString alloc] initWithBytes:h->name length:strnlen(h->name, 100) encoding:NSUTF8StringEncoding] ?: @"";
        NSString *prefix = [[NSString alloc] initWithBytes:h->prefix length:strnlen(h->prefix, 155) encoding:NSUTF8StringEncoding] ?: @"";
        if (prefix.length) name = [prefix stringByAppendingPathComponent:name];
        unsigned long long size = NDTarOctal(h->size, sizeof(h->size));
        NSUInteger padded = (NSUInteger)((size + 511ULL) / 512ULL * 512ULL);
        char type = h->typeflag ? h->typeflag : '0';

        if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            off += padded;
            continue;
        }
        // refuse path escape
        if ([name hasPrefix:@"/"] || [name containsString:@".."]) {
            off += padded;
            continue;
        }
        NSString *full = [destDir stringByAppendingPathComponent:name];

        if (type == '5' || [name hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:full withIntermediateDirectories:YES attributes:nil error:nil];
        } else if (type == '0' || type == '\0') {
            NSString *parent = [full stringByDeletingLastPathComponent];
            [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            NSUInteger payload = (NSUInteger)MIN(size, (unsigned long long)(len > off ? len - off : 0));
            NSData *fileData = [NSData dataWithBytes:bytes + off length:payload];
            [fileData writeToFile:full atomically:YES];
            written++;
        }
        off += padded;
    }
    if (written == 0) {
        // directory-only archives still OK if dest has anything
        NSArray *kids = [fm contentsOfDirectoryAtPath:destDir error:nil];
        if (!kids.count) {
            if (error) *error = [NSError errorWithDomain:@"NDArchive" code:5 userInfo:@{NSLocalizedDescriptionKey: @"tar 内没有可提取的文件"}];
            return NO;
        }
    }
    return YES;
}

static BOOL NDExtractBuiltin(NSString *archivePath, NSString *destDir, NSError **error) {
    NSData *raw = [NSData dataWithContentsOfFile:archivePath options:0 error:error];
    if (!raw.length) return NO;
    const uint8_t *b = raw.bytes;
    NSData *tar = raw;
    NSString *lower = archivePath.lowercaseString;

    BOOL looksGzip = raw.length >= 2 && b[0] == 0x1f && b[1] == 0x8b;
    BOOL nameGzip = [lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"] || [lower hasSuffix:@".gz"];
    if (looksGzip || nameGzip) {
        NSError *gzErr = nil;
        tar = NDGunzipData(raw, &gzErr);
        if (!tar) {
            if (error) *error = gzErr;
            return NO;
        }
    }
    // ustar / bare tar
    return NDExtractTarBytes(tar, destDir, error);
}

BOOL NDExtractArchiveToDirectory(NSString *archivePath, NSString *destDir, NSError **error) {
    if (!archivePath.length || !destDir.length) {
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:10 userInfo:@{NSLocalizedDescriptionKey: @"路径为空"}];
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:archivePath]) {
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:11 userInfo:@{NSLocalizedDescriptionKey: @"压缩包不存在"}];
        return NO;
    }
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *lower = archivePath.lowercaseString;
    NSString *qArch = [archivePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *qDest = [destDir stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    // 1) Prefer system tools via sh (handles spaces in paths)
    if ([lower hasSuffix:@".zip"]) {
        NSString *cmd = [NSString stringWithFormat:@"unzip -o '%@' -d '%@'", qArch, qDest];
        if (NDSpawnShell(cmd)) return YES;
        // bsdtar can often read zip
        cmd = [NSString stringWithFormat:@"tar -xf '%@' -C '%@'", qArch, qDest];
        if (NDSpawnShell(cmd)) return YES;
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:20 userInfo:@{NSLocalizedDescriptionKey: @"无法解压 zip（设备无 unzip）。请在电脑解压后把文件夹拷进 import。"}];
        return NO;
    }

    if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"]) {
        NSString *cmd = [NSString stringWithFormat:@"tar -xzf '%@' -C '%@'", qArch, qDest];
        if (NDSpawnShell(cmd)) return YES;
        cmd = [NSString stringWithFormat:@"gzip -dc '%@' | tar -xf - -C '%@'", qArch, qDest];
        if (NDSpawnShell(cmd)) return YES;
    } else if ([lower hasSuffix:@".tar"]) {
        NSString *cmd = [NSString stringWithFormat:@"tar -xf '%@' -C '%@'", qArch, qDest];
        if (NDSpawnShell(cmd)) return YES;
    }

    // 2) Built-in gzip + ustar (no external tar required)
    NSError *builtinErr = nil;
    if (NDExtractBuiltin(archivePath, destDir, &builtinErr)) return YES;

    if (error) {
        NSString *msg = builtinErr.localizedDescription ?: @"解压失败";
        *error = [NSError errorWithDomain:@"NDArchive" code:30 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@\n也可在电脑解压后，把记录文件夹直接放进 /var/mobile/Media/AMG/import/", msg]}];
    }
    return NO;
}

static void NDTarWriteOctal(char *dst, size_t n, unsigned long long v) {
    // classic tar: zero-filled octal, NUL-terminated within field
    if (n == 0) return;
    memset(dst, 0, n);
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%llo", v);
    size_t len = strlen(tmp);
    size_t width = n - 1; // leave room for NUL
    if (len >= width) {
        memcpy(dst, tmp + (len - width), width);
    } else {
        memset(dst, '0', width - len);
        memcpy(dst + (width - len), tmp, len);
    }
}

static void NDTarWriteHeader(NSMutableData *out, NSString *relPath, unsigned long long size, char typeflag) {
    NDTarHeader h;
    memset(&h, 0, sizeof(h));
    NSString *path = relPath ?: @"";
    // split prefix/name if needed (ustar)
    NSString *name = path;
    NSString *prefix = @"";
    if (path.length > 100) {
        NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch range:NSMakeRange(0, path.length - 1)];
        if (slash.location != NSNotFound && slash.location <= 155 && (path.length - slash.location - 1) <= 100) {
            prefix = [path substringToIndex:slash.location];
            name = [path substringFromIndex:slash.location + 1];
        } else {
            name = [path substringToIndex:MIN(100, path.length)];
        }
    }
    strncpy(h.name, name.fileSystemRepresentation, sizeof(h.name));
    strncpy(h.prefix, prefix.fileSystemRepresentation, sizeof(h.prefix));
    NDTarWriteOctal(h.mode, sizeof(h.mode), typeflag == '5' ? 0755ULL : 0644ULL);
    NDTarWriteOctal(h.uid, sizeof(h.uid), 501);
    NDTarWriteOctal(h.gid, sizeof(h.gid), 501);
    NDTarWriteOctal(h.size, sizeof(h.size), typeflag == '5' ? 0 : size);
    NDTarWriteOctal(h.mtime, sizeof(h.mtime), (unsigned long long)time(NULL));
    memset(h.chksum, ' ', sizeof(h.chksum));
    h.typeflag = typeflag;
    memcpy(h.magic, "ustar", 5);
    h.magic[5] = '\0';
    memcpy(h.version, "00", 2);

    unsigned int sum = 0;
    const unsigned char *raw = (const unsigned char *)&h;
    for (size_t i = 0; i < sizeof(h); i++) sum += raw[i];
    snprintf(h.chksum, sizeof(h.chksum), "%06o", sum);
    h.chksum[6] = '\0';
    h.chksum[7] = ' ';

    [out appendBytes:&h length:sizeof(h)];
}

BOOL NDCreateTarFromDirectory(NSString *sourceDir, NSString *tarPath, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:sourceDir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:40 userInfo:@{NSLocalizedDescriptionKey: @"源目录不存在"}];
        return NO;
    }
    // Try system tar first
    NSString *parent = [tarPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:tarPath error:nil];
    NSString *base = [sourceDir lastPathComponent];
    NSString *cwd = [sourceDir stringByDeletingLastPathComponent];
    NSString *qTar = [tarPath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *qCwd = [cwd stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *qBase = [base stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *cmd = [NSString stringWithFormat:@"tar -cf '%@' -C '%@' '%@'", qTar, qCwd, qBase];
    if (NDSpawnShell(cmd) && [fm fileExistsAtPath:tarPath]) return YES;

    // Built-in ustar writer
    NSMutableData *out = [NSMutableData data];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:sourceDir];
    // root directory entry
    NDTarWriteHeader(out, base, 0, '5');

    for (NSString *rel in en) {
        NSString *full = [sourceDir stringByAppendingPathComponent:rel];
        NSString *tarRel = [base stringByAppendingPathComponent:rel];
        BOOL entryDir = NO;
        [fm fileExistsAtPath:full isDirectory:&entryDir];
        if (entryDir) {
            NDTarWriteHeader(out, [tarRel hasSuffix:@"/"] ? tarRel : [tarRel stringByAppendingString:@"/"], 0, '5');
            continue;
        }
        NSData *file = [NSData dataWithContentsOfFile:full options:0 error:nil];
        if (!file) file = [NSData data];
        NDTarWriteHeader(out, tarRel, file.length, '0');
        [out appendData:file];
        NSUInteger pad = (512 - (file.length % 512)) % 512;
        if (pad) {
            static char zeros[512];
            [out appendBytes:zeros length:pad];
        }
    }
    // two zero blocks
    static char zend[1024];
    [out appendBytes:zend length:1024];
    if (![out writeToFile:tarPath options:NSDataWritingAtomic error:error]) return NO;
    return YES;
}
