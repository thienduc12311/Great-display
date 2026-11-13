// Private CoreGraphics virtual-display bridge.
//
// The classes below are resolved from the Objective-C runtime at load time and
// are driven through KVC / IMP calls so that no private headers or link-time
// symbols are required. Method names and key names are the documented runtime
// surface of CGVirtualDisplayDescriptor / CGVirtualDisplaySettings /
// CGVirtualDisplayMode / CGVirtualDisplay.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>

#include "gd_virtual_display.h"

struct GDVirtualDisplayRef {
    void *display;      // CGVirtualDisplay instance, retained
    uint32_t displayID;
};

static char gd_last_error[512];

static void gd_set_error(NSString *message) {
    const char *utf8 = message.UTF8String ?: "unknown error";
    strncpy(gd_last_error, utf8, sizeof(gd_last_error) - 1);
    gd_last_error[sizeof(gd_last_error) - 1] = '\0';
}

int gd_virtual_display_available(void) {
    return NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
           NSClassFromString(@"CGVirtualDisplay") != nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

const char *gd_virtual_display_error(void) {
    return gd_last_error;
}

typedef id (*GDInitModeIMP)(id, SEL, unsigned int, unsigned int, double);
typedef id (*GDInitDisplayIMP)(id, SEL, id);

// Declared so `[[cls alloc] initWith…]` compiles as a real init call. Calling
// init through a casted objc_msgSend hides the init family from ARC: the +1
// from alloc was never released, so a "destroyed" virtual display stayed
// connected until the app quit (and could not be re-created meanwhile).
@protocol GDVirtualDisplayInitializers
- (instancetype)initWithDescriptor:(id)descriptor;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
// applySettings: returns BOOL. Calling it through an int-returning signature
// reads register bits the callee never set (visible on Intel).
typedef BOOL (*GDApplySettingsIMP)(id, SEL, id);

GDVirtualDisplayRef *gd_virtual_display_create(const char *name,
                                               uint32_t width,
                                               uint32_t height,
                                               double refresh_rate,
                                               double mm_width,
                                               double mm_height,
                                               uint32_t serial_number,
                                               uint32_t vendor_id,
                                               uint32_t product_id,
                                               int hidpi) {
    gd_last_error[0] = '\0';

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");

    if (!descriptorClass || !displayClass || !settingsClass || !modeClass) {
        gd_set_error(@"CoreGraphics virtual display classes are unavailable on this system.");
        return NULL;
    }
    if (width == 0 || height == 0) {
        gd_set_error(@"Requested virtual display size is invalid.");
        return NULL;
    }

    @try {
        id descriptor = [[descriptorClass alloc] init];
        NSString *displayName = name ? [NSString stringWithUTF8String:name] : @"Great Display";
        // The descriptor describes the panel; the mode describes one timings entry.
        // A HiDPI screen is authored at twice the logical geometry.
        uint32_t pixelWidth = hidpi ? width * 2u : width;
        uint32_t pixelHeight = hidpi ? height * 2u : height;
        uint32_t maxWidth = pixelWidth;
        uint32_t maxHeight = pixelHeight;
        CGSize millimeters = CGSizeMake(mm_width > 0 ? mm_width : 600.0,
                                        mm_height > 0 ? mm_height : 340.0);

        [descriptor setValue:displayName forKey:@"name"];
        [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
        [descriptor setValue:@(maxWidth) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(maxHeight) forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithBytes:&millimeters
                                            objCType:@encode(CGSize)]
                      forKey:@"sizeInMillimeters"];
        [descriptor setValue:@(serial_number ?: 1u) forKey:@"serialNum"];
        [descriptor setValue:@(product_id ?: 0x1234u) forKey:@"productID"];
        [descriptor setValue:@(vendor_id ?: 0x5678u) forKey:@"vendorID"];

        // Optional extended descriptor keys on newer systems (sRGB primaries).
        @try {
            CGPoint red = CGPointMake(0.640, 0.330);
            CGPoint green = CGPointMake(0.300, 0.600);
            CGPoint blue = CGPointMake(0.150, 0.060);
            CGPoint white = CGPointMake(0.3127, 0.3290);
            [descriptor setValue:[NSValue valueWithBytes:&red objCType:@encode(CGPoint)] forKey:@"redPrimary"];
            [descriptor setValue:[NSValue valueWithBytes:&green objCType:@encode(CGPoint)] forKey:@"greenPrimary"];
            [descriptor setValue:[NSValue valueWithBytes:&blue objCType:@encode(CGPoint)] forKey:@"bluePrimary"];
            [descriptor setValue:[NSValue valueWithBytes:&white objCType:@encode(CGPoint)] forKey:@"whitePoint"];
        } @catch (__unused NSException *exception) {
            // Older systems expose fewer descriptor keys; this is optional.
        }

        id display = [(id<GDVirtualDisplayInitializers>)[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) {
            gd_set_error(@"CoreGraphics refused to create the virtual display.");
            return NULL;
        }

        id mode = [(id<GDVirtualDisplayInitializers>)[modeClass alloc] initWithWidth:pixelWidth height:pixelHeight refreshRate:refresh_rate > 0 ? refresh_rate : 60.0];
        if (!mode) {
            gd_set_error(@"CoreGraphics refused to create a display mode.");
            return NULL;
        }

        NSMutableArray *modes = [NSMutableArray arrayWithObject:mode];
        if (hidpi) {
            // Also publish the low-density timing so the resolution list has both variants.
            id lowDensity = [(id<GDVirtualDisplayInitializers>)[modeClass alloc] initWithWidth:width height:height refreshRate:refresh_rate > 0 ? refresh_rate : 60.0];
            if (lowDensity) {
                [modes addObject:lowDensity];
            }
        }

        id settings = [[settingsClass alloc] init];
        [settings setValue:@(hidpi ? 1u : 0u) forKey:@"hiDPI"];
        [settings setValue:modes forKey:@"modes"];

        int result = ((GDApplySettingsIMP)objc_msgSend)(display,
                                                        @selector(applySettings:),
                                                        settings);

        id displayIDValue = nil;
        @try {
            displayIDValue = [display valueForKey:@"displayID"];
        } @catch (__unused NSException *exception) {
            displayIDValue = nil;
        }
        uint32_t displayID = displayIDValue ? [displayIDValue unsignedIntValue] : 0;

        // applySettings answers with a boolean on current systems; the authoritative
        // success signal is that the display reaches the online list.
        BOOL online = NO;
        for (int attempt = 0; attempt < 24 && displayID != 0; attempt++) {
            if (CGDisplayIsOnline(displayID)) {
                online = YES;
                if (CGDisplayIsActive(displayID)) { break; }
            }
            usleep(50 * 1000);
        }
        if (displayID == 0 || !online) {
            gd_set_error([NSString stringWithFormat:@"Virtual display did not come online (apply result %d).", result]);
            return NULL;
        }

        GDVirtualDisplayRef *ref = calloc(1, sizeof(GDVirtualDisplayRef));
        ref->display = (void *)CFBridgingRetain(display);
        ref->displayID = displayID;
        return ref;
    } @catch (NSException *exception) {
        gd_set_error([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
        return NULL;
    }
}

void gd_virtual_display_destroy(GDVirtualDisplayRef *ref) {
    if (!ref) {
        return;
    }
    if (ref->display) {
        CFRelease(ref->display);
        ref->display = NULL;
    }
    free(ref);
}

uint32_t gd_virtual_display_id(GDVirtualDisplayRef *ref) {
    return ref ? ref->displayID : 0;
}

// MARK: - Multi-mode virtual displays

static NSArray *gd_make_modes(Class modeClass,
                              const uint32_t *pixel_widths,
                              const uint32_t *pixel_heights,
                              uint32_t count,
                              double refresh_rate) {
    NSMutableArray *modes = [NSMutableArray arrayWithCapacity:count];
    double rate = refresh_rate > 0 ? refresh_rate : 60.0;
    for (uint32_t index = 0; index < count; index++) {
        if (pixel_widths[index] == 0 || pixel_heights[index] == 0) { continue; }
        id mode = [(id<GDVirtualDisplayInitializers>)[modeClass alloc] initWithWidth:pixel_widths[index] height:pixel_heights[index] refreshRate:rate];
        if (mode) { [modes addObject:mode]; }
    }
    return modes;
}

static int gd_apply_modes(id display, NSArray *modes, int hidpi) {
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!settingsClass || modes.count == 0) { return -1; }
    id settings = [[settingsClass alloc] init];
    [settings setValue:@(hidpi ? 1u : 0u) forKey:@"hiDPI"];
    [settings setValue:modes forKey:@"modes"];
    return ((GDApplySettingsIMP)objc_msgSend)(display, @selector(applySettings:), settings);
}

GDVirtualDisplayRef *gd_virtual_display_create_modes(const char *name,
                                                     const uint32_t *pixel_widths,
                                                     const uint32_t *pixel_heights,
                                                     uint32_t count,
                                                     double refresh_rate,
                                                     double mm_width,
                                                     double mm_height,
                                                     uint32_t serial_number,
                                                     uint32_t vendor_id,
                                                     uint32_t product_id,
                                                     int hidpi,
                                                     uint32_t max_pixels_wide,
                                                     uint32_t max_pixels_high) {
    gd_last_error[0] = '\0';
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !modeClass || count == 0) {
        gd_set_error(@"CoreGraphics virtual display classes are unavailable, or no modes were given.");
        return NULL;
    }
    @try {
        id descriptor = [[descriptorClass alloc] init];
        NSString *displayName = name ? [NSString stringWithUTF8String:name] : @"Great Display";
        CGSize millimeters = CGSizeMake(mm_width > 0 ? mm_width : 600.0, mm_height > 0 ? mm_height : 340.0);
        [descriptor setValue:displayName forKey:@"name"];
        [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
        // The maximum is fixed for the display's lifetime; headroom here is
        // what lets the mode list be replaced later without reconnecting.
        [descriptor setValue:@(max_pixels_wide) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(max_pixels_high) forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithBytes:&millimeters objCType:@encode(CGSize)] forKey:@"sizeInMillimeters"];
        [descriptor setValue:@(serial_number ?: 1u) forKey:@"serialNum"];
        [descriptor setValue:@(product_id ?: 0x1234u) forKey:@"productID"];
        [descriptor setValue:@(vendor_id ?: 0x5678u) forKey:@"vendorID"];
        @try {
            CGPoint red = CGPointMake(0.640, 0.330), green = CGPointMake(0.300, 0.600);
            CGPoint blue = CGPointMake(0.150, 0.060), white = CGPointMake(0.3127, 0.3290);
            [descriptor setValue:[NSValue valueWithBytes:&red objCType:@encode(CGPoint)] forKey:@"redPrimary"];
            [descriptor setValue:[NSValue valueWithBytes:&green objCType:@encode(CGPoint)] forKey:@"greenPrimary"];
            [descriptor setValue:[NSValue valueWithBytes:&blue objCType:@encode(CGPoint)] forKey:@"bluePrimary"];
            [descriptor setValue:[NSValue valueWithBytes:&white objCType:@encode(CGPoint)] forKey:@"whitePoint"];
        } @catch (__unused NSException *exception) {}

        id display = [(id<GDVirtualDisplayInitializers>)[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) {
            gd_set_error(@"CoreGraphics refused to create the virtual display.");
            return NULL;
        }
        NSArray *modes = gd_make_modes(modeClass, pixel_widths, pixel_heights, count, refresh_rate);
        int result = gd_apply_modes(display, modes, hidpi);

        id displayIDValue = nil;
        @try { displayIDValue = [display valueForKey:@"displayID"]; } @catch (__unused NSException *e) {}
        uint32_t displayID = displayIDValue ? [displayIDValue unsignedIntValue] : 0;
        BOOL online = NO;
        for (int attempt = 0; attempt < 24 && displayID != 0; attempt++) {
            if (CGDisplayIsOnline(displayID)) {
                online = YES;
                if (CGDisplayIsActive(displayID)) { break; }
            }
            usleep(50 * 1000);
        }
        if (displayID == 0 || !online) {
            gd_set_error([NSString stringWithFormat:@"Virtual display did not come online (apply result %d).", result]);
            return NULL;
        }
        GDVirtualDisplayRef *ref = calloc(1, sizeof(GDVirtualDisplayRef));
        ref->display = (void *)CFBridgingRetain(display);
        ref->displayID = displayID;
        return ref;
    } @catch (NSException *exception) {
        gd_set_error([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
        return NULL;
    }
}

int gd_virtual_display_set_modes(GDVirtualDisplayRef *ref,
                                 const uint32_t *pixel_widths,
                                 const uint32_t *pixel_heights,
                                 uint32_t count,
                                 double refresh_rate,
                                 int hidpi) {
    if (!ref || !ref->display) { return -1; }
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!modeClass) { return -1; }
    @try {
        id display = (__bridge id)ref->display;
        NSArray *modes = gd_make_modes(modeClass, pixel_widths, pixel_heights, count, refresh_rate);
        // gd_apply_modes returns -1 when it could not even try; only a positive
        // answer counts, so the caller falls back to reconnecting otherwise.
        return gd_apply_modes(display, modes, hidpi) > 0 ? 0 : -2;
    } @catch (NSException *exception) {
        gd_set_error([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
        return -3;
    }
}
