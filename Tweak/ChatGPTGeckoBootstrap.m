#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const CGChatGPTBundleID = @"com.551.chatgpt14";
static NSString * const CGChatGPTURL = @"https://chatgpt.com/";
static const NSInteger CGChatGPTPhoneZoom = 150;

static void CGConfigureChatGPTDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:CGChatGPTURL forKey:@"default.NewTabSettings.customNewTabURL"];

    // Keep ChatGPT in the desktop-capable Gecko mode that exposes the real web
    // Voice controls, but use a less aggressive permanent zoom. 175% made the
    // composer too narrow on iPhone, which caused ChatGPT's mic to reflow/hide
    // and pushed the Voice cancel/confirm controls outside the usable width.
    // 150% keeps the page clearly larger while leaving enough horizontal room
    // for the normal mic/send buttons and the full X / tick Voice bar.
    [defaults setBool:YES forKey:@"default.BrowsingSettings.requestDesktopWebsite"];
    [defaults setInteger:CGChatGPTPhoneZoom forKey:@"default.BrowsingSettings.defaultPageZoomLevel"];

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
