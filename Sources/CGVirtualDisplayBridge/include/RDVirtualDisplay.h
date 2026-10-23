#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A virtual monitor that macOS treats like a physically attached display.
/// The display exists for as long as this object is alive.
@interface RDVirtualDisplay : NSObject

@property (class, readonly) BOOL isSupported;
@property (readonly) CGDirectDisplayID displayID;

/// @param width  Backing width in pixels.
/// @param height Backing height in pixels.
/// @param hiDPI  When YES the display runs at 2x ("Retina"), i.e. width/2 x height/2 points.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSInteger)width
                               height:(NSInteger)height
                                  ppi:(double)ppi
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                               serial:(uint32_t)serial;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
