#import "RDVirtualDisplay.h"

// Private CoreGraphics interfaces (macOS 11+). Classes are looked up at
// runtime with NSClassFromString so nothing private is referenced at link time.

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation RDVirtualDisplay {
    id _display;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSInteger)width
                               height:(NSInteger)height
                                  ppi:(double)ppi
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                               serial:(uint32_t)serial {
    if (!RDVirtualDisplay.isSupported || width <= 0 || height <= 0) {
        return nil;
    }
    if (!(self = [super init])) {
        return nil;
    }

    NSInteger pointsWide = hiDPI ? width / 2 : width;
    NSInteger pointsHigh = hiDPI ? height / 2 : height;
    double mmPerPoint = 25.4 / (ppi > 0 ? ppi : 110.0);

    CGVirtualDisplayDescriptor *descriptor = [(CGVirtualDisplayDescriptor *)[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    [descriptor setDispatchQueue:dispatch_get_main_queue()];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)width;
    descriptor.maxPixelsHigh = (unsigned int)height;
    descriptor.sizeInMillimeters = CGSizeMake(pointsWide * mmPerPoint, pointsHigh * mmPerPoint);
    descriptor.vendorID = 0x5244; // "RD"
    descriptor.productID = 0x0001;
    descriptor.serialNum = serial;

    CGVirtualDisplay *display = [(CGVirtualDisplay *)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (display == nil) {
        return nil;
    }

    CGVirtualDisplayMode *mode = [(CGVirtualDisplayMode *)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:(NSUInteger)pointsWide height:(NSUInteger)pointsHigh refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [(CGVirtualDisplaySettings *)[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[ mode ];
    if (![display applySettings:settings]) {
        return nil;
    }

    _display = display;
    _displayID = display.displayID;
    return self;
}

@end
