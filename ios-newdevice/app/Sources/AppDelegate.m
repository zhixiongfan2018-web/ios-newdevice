#import "AppDelegate.h"
#import "HomeViewController.h"
#import "RecordsViewController.h"
#import "AppsViewController.h"
#import "ToolsViewController.h"
#import "SettingsViewController.h"
#import "NDPaths.h"
#import "NDHTTPServer.h"
#import "NDTheme.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.bgTask = UIBackgroundTaskInvalid;

    @try {
        [NDPaths ensureDirectories];
    } @catch (__unused NSException *e) {
        NSLog(@"[NewDevice] ensureDirectories failed: %@", e);
    }

    [NDTheme applyGlobalAppearance];

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
                                                    image:[UIImage systemImageNamed:@"list.bullet"]
                                            selectedImage:[UIImage systemImageNamed:@"list.bullet"]];

    UINavigationController *apps = [[UINavigationController alloc] initWithRootViewController:[AppsViewController new]];
    apps.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"应用"
                                                    image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                            selectedImage:[UIImage systemImageNamed:@"square.grid.2x2.fill"]];

    UINavigationController *tools = [[UINavigationController alloc] initWithRootViewController:[ToolsViewController new]];
    tools.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"工具"
                                                     image:[UIImage systemImageNamed:@"wrench.and.screwdriver"]
                                             selectedImage:[UIImage systemImageNamed:@"wrench.and.screwdriver.fill"]];

    UINavigationController *set = [[UINavigationController alloc] initWithRootViewController:[SettingsViewController new]];
    set.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                   image:[UIImage systemImageNamed:@"gearshape"]
                                           selectedImage:[UIImage systemImageNamed:@"gearshape.fill"]];

    for (UINavigationController *nav in @[home, recs, apps, tools, set]) {
        nav.navigationBar.prefersLargeTitles = YES;
        nav.navigationBar.tintColor = [NDTheme accent];
    }

    tab.viewControllers = @[home, recs, apps, tools, set];
    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];

    // Start API after UI is up so a bind failure cannot prevent launch.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        if (![[NDHTTPServer shared] ensureRunning:&error]) {
            NSLog(@"[NewDevice] API start failed: %@", error);
        } else {
            NSLog(@"[NewDevice] API ready at http://127.0.0.1:%u/cmd", [NDHTTPServer shared].port ?: (unsigned)NDHTTPPort);
        }
    });

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
