// System display features that macOS only exposes through private frameworks.
//
// Everything is resolved at runtime (dlopen / NSClassFromString / dlsym) and
// every entry point checks for availability first, so a missing class or symbol
// degrades to "unavailable" instead of crashing.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>

#include "gd_system.h"

static void gd_load_frameworks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    });
}

static void *gd_symbol(const char *name) {
    gd_load_frameworks();
    void *pointer = dlsym(RTLD_DEFAULT, name);
    if (!pointer) {
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (handle) pointer = dlsym(handle, name);
    }
    return pointer;
}

// MARK: - MonitorPanel

// MonitorPanel is not thread-safe and throws (e.g. "collection mutated while
// being enumerated") when displays are added or removed during a lookup. Every
// entry point catches exceptions so a framework hiccup can never crash the app;
// callers also use these functions from the main thread only.
// One manager for the whole app lifetime. Each MPDisplayMgr installs a
// background handler for display reconfiguration; creating a manager per call
// and releasing it let that handler run on a freed object while displays were
// being added or removed (EXC_BAD_ACCESS in -[MPDisplayMgr serviceReconfigure:]).
static id gd_mp_manager(void) {
    static id manager = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gd_load_frameworks();
        Class managerClass = NSClassFromString(@"MPDisplayMgr");
        if (!managerClass) return;
        @try {
            SEL shared = NSSelectorFromString(@"sharedMgr");
            if ([managerClass respondsToSelector:shared]) {
                manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, shared);
            }
            if (!manager) manager = [[managerClass alloc] init];
        } @catch (__unused NSException *exception) {
            manager = nil;
        }
    });
    return manager;
}

static id gd_mp_display(uint32_t display_id) {
    @try {
        id manager = gd_mp_manager();
        if (!manager) return nil;
        SEL lookup = NSSelectorFromString(@"displayWithID:");
        if (![manager respondsToSelector:lookup]) return nil;
        return ((id (*)(id, SEL, int))objc_msgSend)(manager, lookup, (int)display_id);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static int gd_bool_call(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return -1;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) ? 1 : 0;
    } @catch (__unused NSException *exception) {
        return -1;
    }
}

int gd_display_can_rotate(uint32_t display_id) {
    return gd_bool_call(gd_mp_display(display_id), @"canChangeOrientation");
}

int gd_display_rotation(uint32_t display_id) {
    id display = gd_mp_display(display_id);
    SEL selector = NSSelectorFromString(@"orientation");
    if (display && [display respondsToSelector:selector]) {
        @try {
            return ((int (*)(id, SEL))objc_msgSend)(display, selector);
        } @catch (__unused NSException *exception) {}
    }
    return (int)CGDisplayRotation(display_id);
}

int gd_display_set_rotation(uint32_t display_id, int degrees) {
    id display = gd_mp_display(display_id);
    SEL selector = NSSelectorFromString(@"setOrientation:");
    if (!display || ![display respondsToSelector:selector]) return -1;
    if (gd_bool_call(display, @"canChangeOrientation") == 0) return -2;
    int normalized = ((degrees % 360) + 360) % 360;
    @try {
        ((void (*)(id, SEL, int))objc_msgSend)(display, selector, normalized);
    } @catch (__unused NSException *exception) {
        return -3;
    }
    return 0;
}

int gd_display_has_hdr(uint32_t display_id) {
    return gd_bool_call(gd_mp_display(display_id), @"hasHDRModes");
}

int gd_display_hdr_enabled(uint32_t display_id) {
    return gd_bool_call(gd_mp_display(display_id), @"preferHDRModes");
}

int gd_display_set_hdr_enabled(uint32_t display_id, int enabled) {
    id display = gd_mp_display(display_id);
    SEL selector = NSSelectorFromString(@"setPreferHDRModes:");
    if (!display || ![display respondsToSelector:selector]) return -1;
    if (gd_bool_call(display, @"hasHDRModes") == 0) return -2;
    @try {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(display, selector, enabled ? YES : NO);
    } @catch (__unused NSException *exception) {
        return -3;
    }
    return 0;
}

// MARK: - Display connection

typedef CGError (*GDConfigureEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);

static GDConfigureEnabledFn gd_configure_enabled(void) {
    GDConfigureEnabledFn fn = (GDConfigureEnabledFn)gd_symbol("SLSConfigureDisplayEnabled");
    if (!fn) fn = (GDConfigureEnabledFn)gd_symbol("CGSConfigureDisplayEnabled");
    return fn;
}

int gd_display_enable_available(void) {
    return gd_configure_enabled() != NULL;
}

int gd_display_set_enabled(uint32_t display_id, int enabled) {
    GDConfigureEnabledFn fn = gd_configure_enabled();
    if (!fn) return -1;
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || !config) return -2;
    CGError error = fn(config, display_id, enabled ? true : false);
    if (error != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return (int)error;
    }
    // Session scope: the display stays disconnected until it is reconnected or
    // the user logs out, also when this app quits or crashes meanwhile.
    error = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    return error == kCGErrorSuccess ? 0 : (int)error;
}

// MARK: - Appearance

int gd_dark_mode(void) {
    BOOL (*get)(void) = (BOOL (*)(void))gd_symbol("SLSGetAppearanceThemeLegacy");
    if (get) return get() ? 1 : 0;
    NSString *style = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
    return [style isEqualToString:@"Dark"] ? 1 : 0;
}

int gd_set_dark_mode(int enabled) {
    void (*set)(BOOL) = (void (*)(BOOL))gd_symbol("SLSSetAppearanceThemeLegacy");
    if (!set) return -1;
    set(enabled ? YES : NO);
    return 0;
}

// MARK: - Night Shift

typedef struct {
    int hour;
    int minute;
} GDBlueLightTime;

typedef struct {
    BOOL active;
    BOOL enabled;
    BOOL sunSchedulePermitted;
    int mode;
    struct { GDBlueLightTime from; GDBlueLightTime to; } schedule;
    unsigned long long disableFlags;
    BOOL available;
} GDBlueLightStatus;

static id gd_blue_light_client(void) {
    gd_load_frameworks();
    static id client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class clientClass = NSClassFromString(@"CBBlueLightClient");
        if (clientClass) client = [[clientClass alloc] init];
    });
    return client;
}

int gd_night_shift(void) {
    id client = gd_blue_light_client();
    SEL selector = NSSelectorFromString(@"getBlueLightStatus:");
    if (!client || ![client respondsToSelector:selector]) return -1;
    GDBlueLightStatus status;
    memset(&status, 0, sizeof(status));
    if (!((BOOL (*)(id, SEL, GDBlueLightStatus *))objc_msgSend)(client, selector, &status)) return -1;
    if (!status.available) return -1;
    return status.enabled ? 1 : 0;
}

int gd_set_night_shift(int enabled) {
    id client = gd_blue_light_client();
    SEL selector = NSSelectorFromString(@"setEnabled:");
    if (!client || ![client respondsToSelector:selector]) return -1;
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(client, selector, enabled ? YES : NO) ? 0 : -2;
}

// MARK: - True Tone

static id gd_true_tone_client(void) {
    gd_load_frameworks();
    static id client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class clientClass = NSClassFromString(@"CBTrueToneClient");
        if (clientClass) client = [[clientClass alloc] init];
    });
    return client;
}

int gd_true_tone_supported(void) {
    id client = gd_true_tone_client();
    if (gd_bool_call(client, @"supported") != 1) return 0;
    return gd_bool_call(client, @"available") == 1 ? 1 : 0;
}

int gd_true_tone(void) {
    if (!gd_true_tone_supported()) return -1;
    return gd_bool_call(gd_true_tone_client(), @"enabled");
}

int gd_set_true_tone(int enabled) {
    id client = gd_true_tone_client();
    SEL selector = NSSelectorFromString(@"setEnabled:");
    if (!client || ![client respondsToSelector:selector] || !gd_true_tone_supported()) return -1;
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(client, selector, enabled ? YES : NO) ? 0 : -2;
}
