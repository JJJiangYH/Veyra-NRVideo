// SPDX-License-Identifier: GPL-3.0-only
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@class VTFrameProcessorFrame;

NS_ASSUME_NONNULL_BEGIN
@interface VeyraInterpolation : NSObject
@property(class, nonatomic, readonly, getter=isSupported) BOOL supported;
@property(class, nonatomic, readonly, getter=isQualitySupported) BOOL qualitySupported;
- (nullable instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height quality:(BOOL)quality multiplier:(NSInteger)multiplier NS_SWIFT_NAME(init(width:height:quality:multiplier:));
- (nullable NSArray<VTFrameProcessorFrame *> *)interpolatePrevious:(CVPixelBufferRef)previous
                             previousTime:(CMTime)previousTime
                                  current:(CVPixelBufferRef)current
                              currentTime:(CMTime)currentTime
    NS_SWIFT_NAME(interpolate(previous:previousTime:current:currentTime:));
@end
@interface VeyraDenoiser : NSObject
@property(class, nonatomic, readonly, getter=isSupported) BOOL supported;
- (nullable instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height format:(OSType)format strength:(float)strength
    NS_SWIFT_NAME(init(width:height:format:strength:));
- (void)reset;
- (nullable CVPixelBufferRef)prepareInput:(CVPixelBufferRef)buffer CF_RETURNS_RETAINED;
- (nullable CVPixelBufferRef)filter:(CVPixelBufferRef)buffer time:(CMTime)time CF_RETURNS_RETAINED;
@end
@interface VeyraOBSOutput : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithCacheDirectory:(NSURL *)directory NS_SWIFT_NAME(init(cacheDirectory:));
- (BOOL)publish:(CVPixelBufferRef)frame;
@end
NS_ASSUME_NONNULL_END

#import "PS5Stream.h"
#import "XboxStream.h"
