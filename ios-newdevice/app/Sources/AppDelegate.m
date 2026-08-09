#import "AppDelegate.h"
#import "HomeViewController.h"
#import "RecordsViewController.h"
#import "AppsViewController.h"
#import "SettingsViewController.h"
#import "NDPaths.h"
#import "NDHTTPServer.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.bgTask = UIBackgroundTaskInvalid;
    [NDPaths ensureDirectories];

    NSError *error = nil;
    if (![[NDHTTPServer shared] ensureRunning:&error]) {
        NSLog(@"[NewDevice] API start failed: %@", error);
    } else {
        NSLog(@"[NewDevice] API ready at http://127.0.0.1:%u/cmd", [NDHTTPServer shared].port ?: (unsigned)NDHTTPPort);
    }

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    UITabBarController *tab = [UITabBarController new];
    UINavigationController *home = [[UINavigationController alloc] initWithRootViewController:[HomeViewController new]];
    home.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"首页" image:[UIImage systemImageNamed:@"house"] tag:0];
    UINavigationController *recs = [[UINavigationController alloc] initWithRootViewController:[RecordsViewController new]];
    recs.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"记录" image:[UIImage systemImageNamed:@"list.bullet"] tag:1];
    UINavigationController *apps = [[UINavigationController alloc] initWithRootViewController:[AppsViewController new]];
    apps.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"应用" image:[UIImage systemImageNamed:@"app.badge"] tag:2];
    UINavigationController *set = [[UINavigationController alloc] initWithRootViewController:[SettingsViewController new]];
    set.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置" image:[UIImage systemImageNamed:@"gearshape"] tag:3];
    tab.viewControllers = @[home, recs, apps, set];

    self.window.rootViewController = tab;
    self.window.tintColor = [UIColor colorWithRed:0.20 green:0.55 blue:0.95 alpha:1];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Keep API alive briefly for scripts (same pattern as AMG needing app foreground/recent)
    if (self.bgTask != UIBackgroundTaskInvalid) return;
    __weak typeof(self) weakSelf = self;
    self.bgTask = [application beginBackgroundTaskWithName:@"NewDeviceAPI" expirationHandler:^{
        if (weakSelf.bgTask != UIBackgroundTaskInvalid) {
            [application endBackgroundTask:weakSelf.bgTask];
            weakSelf.bgTask = UIBackgroundTaskInvalid;
        }
    }];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    NSError *error = nil;
    [[NDHTTPServer shared] ensureRunning:&error];
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [application endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

@end
