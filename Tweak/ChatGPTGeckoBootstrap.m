#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const CGReynardBundleID = @"com.minh-ton.Reynard";
static NSString * const CGChatGPTURL = @"https://chatgpt.com/";

static void CGConfigureChatGPTDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Reynard uses these keys for what a fresh/new tab should display.
    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:CGChatGPTURL forKey:@"default.NewTabSettings.customNewTabURL"];

    // Keep Reynard's own homepage/update cards out of the way if a blank tab is ever shown.
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
        if (![bundleID isEqualToString:CGReynardBundleID]) {
            return;
        }

        // This runs before Reynard creates its first browser tab, so ChatGPT is the page
        // loaded by the embedded Gecko engine instead of Reynard's browser homepage.
        CGConfigureChatGPTDefaults();
    }
}
