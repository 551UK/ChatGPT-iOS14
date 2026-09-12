#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const CGChatGPTBundleID = @"com.551.chatgpt14";
static NSString * const CGChatGPTURL = @"https://chatgpt.com/?q=%E2%80%8C";
static NSString * const CGChatGPTMobileUA = @"Mozilla/5.0 (Android 15; Mobile; rv:155.0) Gecko/155.0 Firefox/155.0";

static void CGConfigureChatGPTDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:CGChatGPTURL forKey:@"default.NewTabSettings.customNewTabURL"];

    // Keep the stable phone layout and mobile Firefox identity. New chats are
    // prefilled with an invisible zero-width non-joiner through the URL above.
    // ChatGPT then treats the composer as non-empty and exposes the real mic
    // immediately, without the user having to type a visible character first.
    [defaults setBool:NO forKey:@"default.BrowsingSettings.requestDesktopWebsite"];
    [defaults setInteger:100 forKey:@"default.BrowsingSettings.defaultPageZoomLevel"];

    [defaults setBool:YES forKey:@"default.CompatibilitySettings.useAndroidUserAgent"];
    [defaults setObject:CGChatGPTMobileUA forKey:@"default.CompatibilitySettings.customUserAgent"];
    [defaults setObject:@"Linux armv81" forKey:@"default.CompatibilitySettings.customPlatform"];
    [defaults setObject:@"5.0 (Android 15)" forKey:@"default.CompatibilitySettings.customAppVersion"];
    [defaults setObject:@"Linux armv81" forKey:@"default.CompatibilitySettings.customOscpu"];
    [defaults setObject:@"" forKey:@"default.CompatibilitySettings.customBuildID"];

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

        CGConfigureChatGPTDefaults();
    }
}
