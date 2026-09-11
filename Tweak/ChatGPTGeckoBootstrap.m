#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const CGChatGPTBundleID = @"com.551.chatgpt14";
static NSString * const CGChatGPTURL = @"https://chatgpt.com/";

static void CGConfigureChatGPTDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:CGChatGPTURL forKey:@"default.NewTabSettings.customNewTabURL"];

    // Reuse the last ChatGPT tab on later launches instead of creating a new
    // hidden Gecko tab every single time. This cuts out the artificial startup
    // delay while still letting the shell create ChatGPT on the first run.
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
