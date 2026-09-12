#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const CGChatGPTBundleID = @"com.551.chatgpt14";
static NSString * const CGChatGPTURL = @"https://chatgpt.com/";
static NSString * const CGChatGPTDesktopUA = @"Mozilla/5.0 (X11; Linux x86_64; rv:155.0) Gecko/20100101 Firefox/155.0";

static void CGConfigureChatGPTDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:CGChatGPTURL forKey:@"default.NewTabSettings.customNewTabURL"];

    // Use Gecko's MOBILE viewport so chatgpt.com lays the composer out for an
    // iPhone instead of rendering the desktop page and then relying on page zoom.
    // Keep a desktop Firefox user-agent through Reynard's compatibility settings
    // so ChatGPT still exposes the real web microphone/Voice controls.
    [defaults setBool:NO forKey:@"default.BrowsingSettings.requestDesktopWebsite"];
    [defaults setInteger:100 forKey:@"default.BrowsingSettings.defaultPageZoomLevel"];

    [defaults setBool:YES forKey:@"default.CompatibilitySettings.useAndroidUserAgent"];
    [defaults setObject:CGChatGPTDesktopUA forKey:@"default.CompatibilitySettings.customUserAgent"];
    [defaults setObject:@"Linux x86_64" forKey:@"default.CompatibilitySettings.customPlatform"];
    [defaults setObject:@"5.0 (X11)" forKey:@"default.CompatibilitySettings.customAppVersion"];
    [defaults setObject:@"Linux x86_64" forKey:@"default.CompatibilitySettings.customOscpu"];
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
