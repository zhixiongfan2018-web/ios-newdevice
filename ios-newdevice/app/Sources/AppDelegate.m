#import "AppDelegate.h"
#import "HomeViewController.h"
#import "RecordsViewController.h"
#import "AppsViewController.h"
#import "SettingsViewController.h"
#import "NDPaths.h"
#import "NDHTTPServer.h"
#import "NDTheme.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.bgTask = UIBackgroundTaskInvalid;
    [NDPaths ensureDirectories];
    [NDTheme applyGlobalAppearance];

    NSError *error = nil;
    if (![[NDHTTPServer shared] ensureRunning:&error]) {
        NSLog(@"[NewDevice] API start failed: %@", error);
    } else {
        NSLog(@"[NewDevice] API ready at http://127.0.0.1:%u/cmd", [NDHTTPServer shared].port ?: (unsigned)NDHTTPPort);
    }

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = [NDTheme accent];
    self.window.backgroundColor = [NDTheme canvas];

    UITabBarController *tab = [UITabBarController new];
    tab.view.backgroundColor = [NDTheme canvas];

    UINavigationController *home = [[UINavigationController alloc] initWithRootViewController:[HomeViewController new]];
    home.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"首页"
                                                    image:[UIImage systemImageNamed:@"house"]
                                            selectedImage:[UIImage systemImageNamed:@"house.fill"]];

    UINavigationController *recs = [[UINavigationController alloc] initWithRootViewController:[RecordsViewController new]];
    recs.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"记录"
                                                    image:[UIImage systemImageNamed:@"rectangle.stack"]
                                            selectedImage:[UIImage systemImageNamed:@"rectangle.stack.fill"]];

    UINavigationController *apps = [[UINavigationController alloc] initWithRootViewController:[AppsViewController new]];
    apps.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"应用"
                                                    image:[UIImage systemImageNamed:@"app.badge"]
                                            selectedImage:[UIImage systemImageNamed:@"app.badge.fill"]];

    UINavigationController *set = [[UINavigationController alloc] initWithRootViewController:[SettingsViewController new]];
    set.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                   image:[UIImage systemImageNamed:@"gearshape"]
                                           selectedImage:[UIImage systemImageNamed:@"gearshape.fill"]];

    for (UINavigationController *nav in @[home, recs, apps, set]) {
        nav.navigationBar.prefersLargeTitles = YES;
        nav.navigationBar.tintColor = [NDTheme accent];
    }

    tab.viewControllers = @[home, recs, apps, set];
    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
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
