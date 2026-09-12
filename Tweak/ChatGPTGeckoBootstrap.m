#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const CGChatGPTBundleID = @"com.551.chatgpt14";
static NSString * const CGChatGPTURL = @"https://chatgpt.com/";
static NSString * const CGChatGPTMobileUA = @"Mozilla/5.0 (Android 15; Mobile; rv:155.0) Gecko/155.0 Firefox/155.0";

static void CGConfigureChatGPTDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:CGChatGPTURL forKey:@"default.NewTabSettings.customNewTabURL"];

    // Keep the stable phone-sized layout from v1.5.13, but identify the Gecko
    // session as a real mobile Firefox browser too. The previous hybrid used a
    // desktop Firefox UA with a mobile viewport, which made ChatGPT choose a
    // desktop composer state: on an empty guest composer the dictation slot was
    // blank until any text was entered. Matching the mobile viewport and UA lets
    // ChatGPT choose its proper mobile composer without the old zoom hacks.
    [defaults setBool:NO forKey:@"default.BrowsingSettings.requestDesktopWebsite"];
    [defaults setInteger:100 forKey:@"default.BrowsingSettings.defaultPageZoomLevel"];

    [defaults setBool:YES forKey:@"default.CompatibilitySettings.useAndroidUserAgent"];
    [defaults setObject:CGChatGPTMobileUA forKey:@"default.CompatibilitySettings.customUserAgent"];
    [defaults setObject:@"Linux armv81" forKey:@"default.CompatibilitySettings.customPlatform"];
    [defaults setObject:@"5.0 (Android 15)" forKey:@"default.CompatibilitySettings.customAppVersion"];
    [defaults setObject:@"Linux armv81" forKey:@"default.CompatibilitySettings.customOscpu"];
    [defaults setObject:@"" forKey:@"default.CompatibilitySettings.customBuildID"];

    // Reuse the last ChatGPT tab on later launches instead of creating a new
    // hidden Gecko tab every single time. This keeps ChatGPT cookies and the
    // guest/account web session in the same Gecko profile.
    [defaults setObject:@"lastTab" forKey:@"default.HomepageSettings.openingScreen"];

    [defaults setBool:NO forKey:@"default.HomepageSettings.showsRecommendations"];
    [defaults setBool:NO forKey:@"default.HomepageSettings.showsNewUpdates"];
    [defaults setBool:NO forKey:@"default.HomepageSettings.showsFavorites"];
    [defaults setBool:NO forKey:@"default.HomepageSettings.showsFrequentlyVisited"];
    [defaults synchronize];
}

__attribute__((constructor))
static void ChatGPTGeckoBootstrapInit(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:CGChatGPTBundleID]) {
            return;
        }

        // Only the separate ChatGPT app gets these defaults. A normal Reynard
        // installation is deliberately left completely untouched.
        CGConfigureChatGPTDefaults();
    }
}
