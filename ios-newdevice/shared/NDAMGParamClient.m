#import "NDAMGParamClient.h"
#import "NDDeviceProfile.h"
#import "NDPaths.h"

@implementation NDAMGParamClient

+ (NSArray<NSString *> *)sidecarPlaintextFileNames {
    return @[
        @"faker_plaintext.plist",
        @"param.plist",
        @"recordParam.plist",
        @"Get_Param.plist",
        @"getRecordParam.plist",
        @"plaintext-faker.plist",
    ];
}

+ (NSArray<NSString *> *)sidecarPlaintextRelativePaths {
    // Classic AMG record root + resolved extract layout (amg_extract / AMG_resolved_*)
    return @[
        @"faker_plaintext.plist",
        @"faker_plaintext.json",
        @"param.plist",
        @"recordParam.plist",
        @"Get_Param.plist",
        @"getRecordParam.plist",
        @"plaintext-faker.plist",
        @"01_plaintext_identity/faker_plaintext.plist",
        @"01_plaintext_identity/faker_plaintext.json",
        @"01_plaintext_identity/param.plist",
        @"01_plaintext_identity/getRecordParam.plist",
    ];
}

+ (BOOL)NDDictUsablePlaintext:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]] || !dict.count) return NO;
    if ([NDDeviceProfile dictionaryLooksLikeEncryptedAMGFaker:dict]) return NO;
    return [NDDeviceProfile dictionaryHasImportableIdentity:dict];
}

+ (NSDictionary *)dictionaryAtPath:(NSString *)path {
    if (!path.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return nil;
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"json"]) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) return nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
    }
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

+ (NSDictionary *)plaintextParamFromSidecarsInDirectory:(NSString *)recordDir
                                            sourcePath:(NSString **)outPath {
    if (!recordDir.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rel in [self sidecarPlaintextRelativePaths]) {
        NSString *p = [recordDir stringByAppendingPathComponent:rel];
        if (![fm fileExistsAtPath:p]) continue;
        NSDictionary *d = [self dictionaryAtPath:p];
        if ([self NDDictUsablePlaintext:d]) {
            if (outPath) *outPath = p;
            return d;
        }
    }
    return nil;
}

+ (NSData *)NDHTTPGet:(NSString *)urlString timeout:(NSTimeInterval)timeout status:(NSInteger *)outStatus {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    __block NSData *data = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = timeout;
    cfg.timeoutIntervalForResource = timeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    [[session dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *resp, __unused NSError *err) {
        data = d;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            status = [(NSHTTPURLResponse *)resp statusCode];
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 1.5) * NSEC_PER_SEC)));
    [session finishTasksAndInvalidate];
    if (outStatus) *outStatus = status;
    return data;
}

+ (BOOL)localAPIIsNewDevice {
    NSInteger st = 0;
    NSData *d = [self NDHTTPGet:@"http://127.0.0.1:8080/" timeout:1.5 status:&st];
    if (!d.length) return NO;
    NSString *body = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    return [body containsString:@"NewDevice"];
}

+ (void)NDMarkResultBusy {
    NSString *two = @"2";
    [two writeToFile:@"/var/mobile/amgResult.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [two writeToFile:[NDPaths resultFilePath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (NSDictionary *)NDLoadParamFile:(NSString *)path {
    if (!path.length) return nil;
    for (NSInteger i = 0; i < 40; i++) { // ~8s
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([self NDDictUsablePlaintext:d]) return d;
        usleep(200 * 1000);
    }
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    return [self NDDictUsablePlaintext:d] ? d : nil;
}

+ (NSDictionary *)fetchPlaintextParamForRecordName:(NSString *)recordName
                                     saveFilePath:(NSString *)saveFilePath
                                            error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!saveFilePath.length) {
        NSString *dir = [[NDPaths mediaHomeDir] stringByAppendingPathComponent:@"tmp"];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        saveFilePath = [dir stringByAppendingPathComponent:@"amg-getRecordParam.plist"];
    }
    [fm createDirectoryAtPath:[saveFilePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:saveFilePath error:nil];
    [self NDMarkResultBusy];

    NSMutableCharacterSet *qset = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [qset removeCharactersInString:@"&+=?"];
    NSString *encName = [recordName.length ? recordName : @"" stringByAddingPercentEncodingWithAllowedCharacters:qset] ?: @"";
    NSString *encPath = [saveFilePath stringByAddingPercentEncodingWithAllowedCharacters:qset] ?: saveFilePath;

    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    if (recordName.length) {
        [urls addObject:[NSString stringWithFormat:
                         @"http://127.0.0.1:8080/cmd?fun=getRecordParam&recordName=%@&saveFilePath=%@",
                         encName, encPath]];
    }
    [urls addObject:[NSString stringWithFormat:
                     @"http://127.0.0.1:8080/cmd?fun=getCurrentRecordParam&saveFilePath=%@",
                     encPath]];

    NSError *last = nil;
    for (NSString *url in urls) {
        NSInteger st = 0;
        NSData *body = [self NDHTTPGet:url timeout:8.0 status:&st];
        NSDictionary *fromFile = [self NDLoadParamFile:saveFilePath];
        if (fromFile) return fromFile;
        if (body.length > 8) {
            id obj = [NSPropertyListSerialization propertyListWithData:body options:0 format:NULL error:nil];
            if ([self NDDictUsablePlaintext:obj]) {
                [(NSDictionary *)obj writeToFile:saveFilePath atomically:YES];
                return (NSDictionary *)obj;
            }
        }
        fromFile = [NSDictionary dictionaryWithContentsOfFile:saveFilePath];
        if ([self NDDictUsablePlaintext:fromFile]) return fromFile;
        last = [NSError errorWithDomain:@"NDAMGParamClient" code:(st ?: 1) userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"getRecordParam failed (%@)", recordName.length ? recordName : @"current"]
        }];
    }
    if (error && last) *error = last;
    return nil;
}

+ (NSDictionary *)resolvePlaintextParamForAMGRecordDir:(NSString *)recordDir
                                          recordTitle:(NSString *)recordTitle
                                           sourceNote:(NSString **)outNote {
    NSString *sidePath = nil;
    NSDictionary *side = [self plaintextParamFromSidecarsInDirectory:recordDir sourcePath:&sidePath];
    if (side) {
        if (outNote) *outNote = [NSString stringWithFormat:@"sidecar %@", sidePath.lastPathComponent];
        return side;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *outPlist = [recordDir stringByAppendingPathComponent:@"faker_plaintext.plist"];
    NSError *err = nil;

    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    if (recordTitle.length) [names addObject:recordTitle];
    NSString *folder = recordDir.lastPathComponent;
    if (folder.length) [names addObject:folder];
    NSDictionary *desc = [NSDictionary dictionaryWithContentsOfFile:[recordDir stringByAppendingPathComponent:@"description.plist"]];
    if ([desc[@"title"] isKindOfClass:[NSString class]] && [desc[@"title"] length]) {
        [names addObject:desc[@"title"]];
    }

    BOOL isND = [self localAPIIsNewDevice];
    for (NSString *name in names) {
        NSDictionary *d = [self fetchPlaintextParamForRecordName:name saveFilePath:outPlist error:&err];
        if ([self NDDictUsablePlaintext:d]) {
            [d writeToFile:outPlist atomically:YES];
            if (outNote) {
                *outNote = [NSString stringWithFormat:@"getRecordParam recordName=%@", name];
            }
            return d;
        }
    }

    NSDictionary *cur = [self fetchPlaintextParamForRecordName:@"" saveFilePath:outPlist error:&err];
    if ([self NDDictUsablePlaintext:cur]) {
        [cur writeToFile:outPlist atomically:YES];
        if (outNote) *outNote = @"getCurrentRecordParam";
        return cur;
    }

    if (outNote) {
        if (isND) {
            *outNote = @"8080 is NewDevice (no AMG runtime decrypt). Save AMG Get_Param / getRecordParam output as faker_plaintext.plist beside faker.plist, then re-import.";
        } else {
            *outNote = @"getRecordParam returned no usable plaintext (start AMG, select the record, retry).";
        }
    }
    (void)fm;
    return nil;
}

@end
