#import "NDHTTPServer.h"
#import "NDOperationService.h"
#import "NDPaths.h"
#import "NDRecordStore.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>

@interface NDHTTPServer ()
@property (nonatomic, assign, readwrite) BOOL running;
@property (nonatomic, assign, readwrite) uint16_t port;
@property (nonatomic, assign) int serverFD;
@property (nonatomic, strong) dispatch_queue_t acceptQueue;
@end

@implementation NDHTTPServer

+ (instancetype)shared {
    static NDHTTPServer *server;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        server = [NDHTTPServer new];
    });
    return server;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverFD = -1;
        _port = (uint16_t)NDHTTPPort;
        _acceptQueue = dispatch_queue_create("com.local.newdevice.http", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (NSDictionary<NSString *, NSString *> *)parseQuery:(NSString *)query {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (!query.length) return dict;
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count >= 2) {
            NSString *key = kv[0];
            NSString *val = [[kv subarrayWithRange:NSMakeRange(1, kv.count - 1)] componentsJoinedByString:@"="];
            // application/x-www-form-urlencoded: '+' means space (before percent-decode)
            key = [key stringByReplacingOccurrencesOfString:@"+" withString:@" "];
            val = [val stringByReplacingOccurrencesOfString:@"+" withString:@" "];
            key = [key stringByRemovingPercentEncoding] ?: key;
            val = [val stringByRemovingPercentEncoding] ?: val;
            dict[key] = val;
        }
    }
    return dict;
}

- (void)sendResponse:(int)clientFD code:(NSInteger)code body:(NSString *)body {
    NSString *status = code == 200 ? @"200 OK" : (code == 404 ? @"404 Not Found" : @"500 Internal Server Error");
    NSData *data = [(body ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSString *header = [NSString stringWithFormat:
                        @"HTTP/1.1 %@\r\n"
                        @"Content-Type: text/plain; charset=utf-8\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Connection: close\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"\r\n",
                        status, (unsigned long)data.length];
    send(clientFD, header.UTF8String, header.length, 0);
    if (data.length) send(clientFD, data.bytes, data.length, 0);
    close(clientFD);
}

- (void)handleClient:(int)clientFD {
    char buffer[8192];
    ssize_t n = recv(clientFD, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) {
        close(clientFD);
        return;
    }
    buffer[n] = '\0';
    NSString *req = [[NSString alloc] initWithBytes:buffer length:n encoding:NSUTF8StringEncoding] ?: @"";
    NSArray *lines = [req componentsSeparatedByString:@"\r\n"];
    NSString *requestLine = lines.firstObject ?: @"";
    NSArray *parts = [requestLine componentsSeparatedByString:@" "];
    NSString *path = parts.count >= 2 ? parts[1] : @"/";

    // Normalize: support /cmd?fun=... and /?fun=...
    NSString *pathOnly = path;
    NSString *queryString = nil;
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        pathOnly = [path substringToIndex:q.location];
        queryString = [path substringFromIndex:q.location + 1];
    }

    NSDictionary *query = [self parseQuery:queryString];
    NSString *fun = query[@"fun"];
    NSMutableDictionary *params = [query mutableCopy] ?: [NSMutableDictionary dictionary];
    [params removeObjectForKey:@"fun"];

    if ([pathOnly isEqualToString:@"/"] || [pathOnly isEqualToString:@"/status"] || ([pathOnly isEqualToString:@"/cmd"] && !fun.length)) {
        [self sendResponse:clientFD code:200 body:@"NewDevice API OK\nTry: /cmd?fun=newRecord\n(Keep NewDevice app in foreground)"];
        return;
    }

    if (!fun.length) {
        [self sendResponse:clientFD code:404 body:@"missing fun"];
        return;
    }

    // AMG-compatible: long tasks ACK 200 immediately; scripts poll result file.
    if ([NDOperationService isAsyncAckFun:fun]) {
        [[NDRecordStore shared] writeResultCode:2];
        [self sendResponse:clientFD code:200 body:@"accepted"];
        [[NDOperationService shared] runAsync:fun query:params completion:^(__unused NSString *body, __unused NSInteger httpCode) {
            // result file already written inside service
        }];
        return;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *respBody = @"";
    __block NSInteger code = 500;
    [[NDOperationService shared] runAsync:fun query:params completion:^(NSString *body, NSInteger httpCode) {
        respBody = body ?: @"";
        code = httpCode;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    [self sendResponse:clientFD code:code body:respBody];
}

- (BOOL)probeLocalAPI {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 400000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)NDHTTPPort);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    BOOL ok = NO;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        const char *req = "GET /status HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        send(fd, req, strlen(req), 0);
        char buf[128];
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n > 0) {
            buf[n] = '\0';
            ok = (strstr(buf, "200") != NULL);
        }
    }
    close(fd);
    return ok;
}

- (BOOL)startWithPort:(uint16_t)port error:(NSError **)error {
    if (self.running) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:@"NDHTTPServer" code:errno userInfo:@{NSLocalizedDescriptionKey: @"socket failed"}];
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_REUSEPORT
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    // Listen on localhost only (scripts + on-device Safari)
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        if (error) *error = [NSError errorWithDomain:@"NDHTTPServer" code:errno userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"bind :%u failed (errno=%d). Another process may own the port.", port, errno]}];
        close(fd);
        return NO;
    }
    if (listen(fd, 32) < 0) {
        if (error) *error = [NSError errorWithDomain:@"NDHTTPServer" code:errno userInfo:@{NSLocalizedDescriptionKey: @"listen failed"}];
        close(fd);
        return NO;
    }
    self.serverFD = fd;
    self.port = port;
    self.running = YES;
    [NDPaths ensureDirectories];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (self.running) {
            struct sockaddr_in clientAddr;
            socklen_t len = sizeof(clientAddr);
            int client = accept(fd, (struct sockaddr *)&clientAddr, &len);
            if (client < 0) {
                if (!self.running) break;
                continue;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                [self handleClient:client];
            });
        }
    });
    NSLog(@"[NewDevice] HTTP API listening on http://127.0.0.1:%u/cmd", port);
    return YES;
}

- (BOOL)ensureRunning:(NSError **)error {
    if (self.running) return YES;
    if ([self probeLocalAPI]) {
        // Daemon or another instance already serving
        return YES;
    }
    return [self startWithPort:(uint16_t)NDHTTPPort error:error];
}

- (void)stop {
    self.running = NO;
    if (self.serverFD >= 0) {
        close(self.serverFD);
        self.serverFD = -1;
    }
}

@end
