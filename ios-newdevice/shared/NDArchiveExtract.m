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

static BOOL NDDestHasContent(NSString *destDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:destDir];
    for (NSString *rel in en) {
        if ([rel hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        NSString *full = [destDir stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) return YES;
        // directory with known markers counts
        for (NSString *m in @[@"faker.plist", @"profile.plist", @"description.plist"]) {
            if ([fm fileExistsAtPath:[full stringByAppendingPathComponent:m]]) return YES;
        }
    }
    NSArray *kids = [fm contentsOfDirectoryAtPath:destDir error:nil] ?: @[];
    return kids.count > 0;
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
    if (inflateInit2(&strm, 15 + 16) != Z_OK) {
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:3 userInfo:@{NSLocalizedDescriptionKey: @"inflateInit 失败"}];
        return nil;
    }
    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)gz.length;
    NSMutableData *out = [NSMutableData dataWithLength:MAX((NSUInteger)gz.length * 4, (NSUInteger)256 * 1024)];
    int ret = Z_OK;
    while (ret == Z_OK) {
        if (strm.total_out >= out.length) {
            [out increaseLengthBy:MAX(out.length, (NSUInteger)1024 * 1024)];
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

static unsigned long long NDTarParseSize(const char *s, size_t n) {
    if (n == 0) return 0;
    // GNU base-256 (high bit set)
    if ((unsigned char)s[0] == 0x80 || (unsigned char)s[0] == 0xff) {
        unsigned long long v = 0;
        for (size_t i = 1; i < n; i++) {
            v = (v << 8) | (unsigned char)s[i];
        }
        return v;
    }
    unsigned long long v = 0;
    for (size_t i = 0; i < n && s[i]; i++) {
        char c = s[i];
        if (c == ' ' || c == '\0') continue;
        if (c < '0' || c > '7') break;
        v = (v << 3) + (unsigned long long)(c - '0');
    }
    return v;
}

static NSString *NDTarDecodeName(const char *bytes, size_t maxLen) {
    size_t n = strnlen(bytes, maxLen);
    if (n == 0) return @"";
    NSString *s = [[NSString alloc] initWithBytes:bytes length:n encoding:NSUTF8StringEncoding];
    if (s) return s;
    s = [[NSString alloc] initWithBytes:bytes length:n encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

static NSString *NDTarSanitizePath(NSString *name) {
    if (!name.length) return @"";
    NSString *n = name;
    // Normalize separators
    n = [n stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    while ([n hasPrefix:@"./"]) n = [n substringFromIndex:2];
    // AMG / macOS tars often store absolute paths — strip leading slashes instead of skipping
    while ([n hasPrefix:@"/"]) n = [n substringFromIndex:1];
    // Drop private/var → var (common Apple layout)
    if ([n hasPrefix:@"private/var/"]) n = [n substringFromIndex:@"private/".length];
    // Reject parent escapes after sanitize
    for (NSString *part in [n componentsSeparatedByString:@"/"]) {
        if ([part isEqualToString:@".."]) return @"";
    }
    return n;
}

static NSString *NDTarPaxPath(NSData *payload) {
    // pax records: "LEN key=value\n"
    NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:payload encoding:NSISOLatin1StringEncoding];
    if (!text.length) return nil;
    NSString *found = nil;
    NSUInteger i = 0;
    while (i < text.length) {
        NSRange sp = [text rangeOfString:@" " options:0 range:NSMakeRange(i, text.length - i)];
        if (sp.location == NSNotFound) break;
        NSInteger len = [[text substringWithRange:NSMakeRange(i, sp.location - i)] integerValue];
        if (len <= 0) break;
        if (i + (NSUInteger)len > text.length) break;
        NSString *rec = [text substringWithRange:NSMakeRange(i, (NSUInteger)len)];
        NSRange eq = [rec rangeOfString:@"="];
        if (eq.location != NSNotFound) {
            NSString *key = [rec substringWithRange:NSMakeRange(sp.location - i + 1, eq.location - (sp.location - i + 1))];
            NSString *val = [rec substringFromIndex:eq.location + 1];
            if ([val hasSuffix:@"\n"]) val = [val substringToIndex:val.length - 1];
            if ([key isEqualToString:@"path"] || [key isEqualToString:@"linkpath"]) found = val;
        }
        i += (NSUInteger)len;
    }
    return found;
}

static BOOL NDExtractTarBytes(NSData *tar, NSString *destDir, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    const uint8_t *bytes = tar.bytes;
    NSUInteger len = tar.length;
    NSUInteger off = 0;
    NSUInteger written = 0;
    NSString *pendingLongName = nil;
    NSString *pendingPaxPath = nil;

    while (off + 512 <= len) {
        const NDTarHeader *h = (const NDTarHeader *)(bytes + off);
        off += 512;
        BOOL allZero = YES;
        for (int i = 0; i < 512; i++) {
            if (((const uint8_t *)h)[i] != 0) { allZero = NO; break; }
        }
        if (allZero) break;

        unsigned long long size = NDTarParseSize(h->size, sizeof(h->size));
        NSUInteger padded = (NSUInteger)((size + 511ULL) / 512ULL * 512ULL);
        NSUInteger payloadLen = (NSUInteger)MIN(size, (unsigned long long)(len > off ? len - off : 0));
        NSData *payload = (payloadLen > 0) ? [NSData dataWithBytes:bytes + off length:payloadLen] : [NSData data];
        char type = h->typeflag ? h->typeflag : '0';

        // GNU long name / long link
        if (type == 'L' || type == 'K') {
            NSString *longName = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]
                ?: [[NSString alloc] initWithData:payload encoding:NSISOLatin1StringEncoding];
            if ([longName hasSuffix:@"\0"]) longName = [longName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
            if (type == 'L') pendingLongName = longName;
            off += padded;
            continue;
        }
        // pax extended header
        if (type == 'x' || type == 'g') {
            if (type == 'x') {
                NSString *p = NDTarPaxPath(payload);
                if (p.length) pendingPaxPath = p;
            }
            off += padded;
            continue;
        }

        NSString *name = pendingPaxPath.length ? pendingPaxPath : (pendingLongName.length ? pendingLongName : nil);
        pendingPaxPath = nil;
        pendingLongName = nil;
        if (!name.length) {
            NSString *base = NDTarDecodeName(h->name, sizeof(h->name));
            NSString *prefix = NDTarDecodeName(h->prefix, sizeof(h->prefix));
            name = prefix.length ? [prefix stringByAppendingPathComponent:base] : base;
        }
        name = NDTarSanitizePath(name);

        if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            off += padded;
            continue;
        }

        NSString *full = [destDir stringByAppendingPathComponent:name];

        if (type == '5' || [name hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:full withIntermediateDirectories:YES attributes:nil error:nil];
        } else if (type == '0' || type == '\0' || type == '7') { // 7 = contiguous file
            NSString *parent = [full stringByDeletingLastPathComponent];
            [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            [payload writeToFile:full atomically:YES];
            written++;
        } else if (type == '1' || type == '2') {
            // hard/symlink — ignore content, keep layout via parent dirs
            NSString *parent = [full stringByDeletingLastPathComponent];
            [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        }
        // other types: skip payload
        off += padded;
    }

    if (written == 0 && !NDDestHasContent(destDir)) {
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:5 userInfo:@{NSLocalizedDescriptionKey: @"tar 内没有可提取的文件（可能是损坏包或空包）"}];
        return NO;
    }
    return YES;
}

static BOOL NDExtractBuiltin(NSString *archivePath, NSString *destDir, NSError **error) {
    NSError *readErr = nil;
    NSData *raw = [NSData dataWithContentsOfFile:archivePath options:NSDataReadingMappedIfSafe error:&readErr];
    if (!raw.length) {
        if (error) *error = readErr ?: [NSError errorWithDomain:@"NDArchive" code:12 userInfo:@{NSLocalizedDescriptionKey: @"无法读取压缩包"}];
        return NO;
    }
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
    // Some "tar.gz" are actually plain ustar already gunzipped by sender wrongly named — handled above.
    // If still looks like gzip magic after "gunzip" failure path skipped — already handled.
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
    [fm removeItemAtPath:destDir error:nil];
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *lower = archivePath.lowercaseString;
    NSString *qArch = [archivePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *qDest = [destDir stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    // Prefer built-in first for .tar/.tar.gz — system tar on Dopamine is often missing,
    // and when present may mishandle absolute paths. Builtin strips leading '/'.
    if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"] || [lower hasSuffix:@".tar"] || [lower hasSuffix:@".gz"]) {
        NSError *builtinErr = nil;
        if (NDExtractBuiltin(archivePath, destDir, &builtinErr) && NDDestHasContent(destDir)) return YES;
        // Fall back to system tools
        NSArray *cmds = nil;
        if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"]) {
            cmds = @[
                [NSString stringWithFormat:@"tar -xzf '%@' -C '%@'", qArch, qDest],
                [NSString stringWithFormat:@"/var/jb/usr/bin/tar -xzf '%@' -C '%@'", qArch, qDest],
                [NSString stringWithFormat:@"gzip -dc '%@' | tar -xf - -C '%@'", qArch, qDest],
                [NSString stringWithFormat:@"gzip -dc '%@' | /var/jb/usr/bin/tar -xf - -C '%@'", qArch, qDest],
            ];
        } else {
            cmds = @[
                [NSString stringWithFormat:@"tar -xf '%@' -C '%@'", qArch, qDest],
                [NSString stringWithFormat:@"/var/jb/usr/bin/tar -xf '%@' -C '%@'", qArch, qDest],
            ];
        }
        for (NSString *cmd in cmds) {
            [fm removeItemAtPath:destDir error:nil];
            [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
            if (NDSpawnShell(cmd) && NDDestHasContent(destDir)) return YES;
        }
        if (error) {
            NSString *msg = builtinErr.localizedDescription ?: @"解压失败";
            *error = [NSError errorWithDomain:@"NDArchive" code:30 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@\n也可在电脑解压后，把记录文件夹直接放进 /var/mobile/Media/AMG/import/ 或 Media/NewDevice/import/", msg]}];
        }
        return NO;
    }

    if ([lower hasSuffix:@".zip"]) {
        NSArray *cmds = @[
            [NSString stringWithFormat:@"unzip -o '%@' -d '%@'", qArch, qDest],
            [NSString stringWithFormat:@"/var/jb/usr/bin/unzip -o '%@' -d '%@'", qArch, qDest],
            [NSString stringWithFormat:@"tar -xf '%@' -C '%@'", qArch, qDest],
        ];
        for (NSString *cmd in cmds) {
            [fm removeItemAtPath:destDir error:nil];
            [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
            if (NDSpawnShell(cmd) && NDDestHasContent(destDir)) return YES;
        }
        if (error) *error = [NSError errorWithDomain:@"NDArchive" code:20 userInfo:@{NSLocalizedDescriptionKey: @"无法解压 zip。请在电脑解压后把文件夹拷进 import。"}];
        return NO;
    }

    // Unknown extension: try builtin as tar/gzip anyway
    NSError *builtinErr = nil;
    if (NDExtractBuiltin(archivePath, destDir, &builtinErr) && NDDestHasContent(destDir)) return YES;
    if (error) {
        *error = [NSError errorWithDomain:@"NDArchive" code:30 userInfo:@{NSLocalizedDescriptionKey: builtinErr.localizedDescription ?: @"解压失败"}];
    }
    return NO;
}

static void NDTarWriteOctal(char *dst, size_t n, unsigned long long v) {
    if (n == 0) return;
    memset(dst, 0, n);
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%llo", v);
    size_t len = strlen(tmp);
    size_t width = n - 1;
    if (len >= width) {
        memcpy(dst, tmp + (len - width), width);
    } else {
        memset(dst, '0', width - len);
        memcpy(dst + (width - len), tmp, len);
    }
}

// Never use NSString.fileSystemRepresentation here: empty strings throw on iOS 18+.
static void NDTarCopyPathField(char *dst, size_t dstSize, NSString *s) {
    if (!dst || dstSize == 0) return;
    memset(dst, 0, dstSize);
    if (!s.length) return;
    NSData *utf8 = [s dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    if (!utf8.length) return;
    size_t n = MIN(dstSize - 1, (size_t)utf8.length);
    memcpy(dst, utf8.bytes, n);
}

static void NDTarWriteHeader(NSMutableData *out, NSString *relPath, unsigned long long size, char typeflag) {
    NDTarHeader h;
    memset(&h, 0, sizeof(h));
    NSString *path = relPath ?: @"";
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
    NDTarCopyPathField(h.name, sizeof(h.name), name);
    NDTarCopyPathField(h.prefix, sizeof(h.prefix), prefix);
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
    NSString *parent = [tarPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:tarPath error:nil];
    NSString *base = [sourceDir lastPathComponent];
    NSString *cwd = [sourceDir stringByDeletingLastPathComponent];
    NSString *qTar = [tarPath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *qCwd = [cwd stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *qBase = [base stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSArray *cmds = @[
        [NSString stringWithFormat:@"tar -cf '%@' -C '%@' '%@'", qTar, qCwd, qBase],
        [NSString stringWithFormat:@"/var/jb/usr/bin/tar -cf '%@' -C '%@' '%@'", qTar, qCwd, qBase],
        [NSString stringWithFormat:@"/var/jb/bin/tar -cf '%@' -C '%@' '%@'", qTar, qCwd, qBase],
    ];
    for (NSString *cmd in cmds) {
        if (NDSpawnShell(cmd) && [fm fileExistsAtPath:tarPath]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:tarPath error:nil];
            if ([attrs fileSize] > 0) return YES;
        }
        [fm removeItemAtPath:tarPath error:nil];
    }

    // Builtin fallback: stream to disk (avoid jetsam) and never call fileSystemRepresentation.
    @try {
        NSMutableData *out = [NSMutableData dataWithCapacity:64 * 1024];
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:sourceDir];
        NDTarWriteHeader(out, base, 0, '5');

        for (NSString *rel in en) {
            if (![rel isKindOfClass:[NSString class]] || !rel.length) continue;
            NSString *full = [sourceDir stringByAppendingPathComponent:rel];
            NSString *tarRel = [base stringByAppendingPathComponent:rel];
            BOOL entryDir = NO;
            [fm fileExistsAtPath:full isDirectory:&entryDir];
            if (entryDir) {
                NDTarWriteHeader(out, [tarRel hasSuffix:@"/"] ? tarRel : [tarRel stringByAppendingString:@"/"], 0, '5');
                continue;
            }
            NSData *file = nil;
            @try {
                file = [NSData dataWithContentsOfFile:full options:NSDataReadingMappedIfSafe error:nil];
            } @catch (__unused NSException *ex) {
                file = nil;
            }
            if (!file) file = [NSData data];
            NDTarWriteHeader(out, tarRel, file.length, '0');
            [out appendData:file];
            NSUInteger pad = (512 - (file.length % 512)) % 512;
            if (pad) {
                static char zeros[512];
                [out appendBytes:zeros length:pad];
            }
            // Flush periodically so peak RSS stays bounded on large sandboxes.
            if (out.length > 8 * 1024 * 1024) {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:tarPath];
                if (!fh) {
                    [[NSData data] writeToFile:tarPath atomically:NO];
                    fh = [NSFileHandle fileHandleForWritingAtPath:tarPath];
                }
                if (!fh) {
                    if (error) *error = [NSError errorWithDomain:@"NDArchive" code:41 userInfo:@{NSLocalizedDescriptionKey: @"无法写入 tar"}];
                    return NO;
                }
                [fh seekToEndOfFile];
                [fh writeData:out];
                [fh closeFile];
                [out setLength:0];
            }
        }
        static char zend[1024];
        [out appendBytes:zend length:1024];
        if ([fm fileExistsAtPath:tarPath]) {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:tarPath];
            [fh seekToEndOfFile];
            [fh writeData:out];
            [fh closeFile];
        } else if (![out writeToFile:tarPath options:0 error:error]) {
            return NO;
        }
        return YES;
    } @catch (NSException *ex) {
        [fm removeItemAtPath:tarPath error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"NDArchive" code:42
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"打包异常：%@ — %@", ex.name ?: @"?", ex.reason ?: @"?"]}];
        }
        return NO;
    }
}
