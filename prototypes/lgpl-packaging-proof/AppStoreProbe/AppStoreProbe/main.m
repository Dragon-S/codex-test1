#import <Cocoa/Cocoa.h>
#import <mpv/client.h>

@interface ProbeDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@end

@implementation ProbeDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    NSRect frame = NSMakeRect(0, 0, 560, 220);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"LGPL App Store Packaging Probe";
    [self.window center];

    mpv_handle *handle = mpv_create();
    int initializeResult = MPV_ERROR_NOMEM;
    if (handle != NULL) {
        mpv_set_option_string(handle, "config", "no");
        mpv_set_option_string(handle, "terminal", "no");
        mpv_set_option_string(handle, "vo", "null");
        mpv_set_option_string(handle, "ao", "null");
        initializeResult = mpv_initialize(handle);
    }

    uint64_t apiVersion = mpv_client_api_version();
    NSString *status = [NSString
        stringWithFormat:@"libmpv API %llu.%llu\nmpv_initialize: %s\n"
                          "沙盒进程已加载通用动态依赖闭包。",
                         apiVersion >> 16,
                         apiVersion & 0xffff,
                         mpv_error_string(initializeResult)];

    NSTextField *label = [NSTextField wrappingLabelWithString:status];
    label.frame = NSMakeRect(32, 48, 496, 124);
    label.font = [NSFont monospacedSystemFontOfSize:15
                                           weight:NSFontWeightRegular];
    self.window.contentView = label;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (handle != NULL) {
        mpv_terminate_destroy(handle);
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
