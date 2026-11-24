// SPDX-License-Identifier: GPL-3.0-only
#import "Interpolation.h"
#import <VideoToolbox/VideoToolbox.h>

@implementation VeyraInterpolation {
    VTFrameProcessor *_processor;
    CVPixelBufferPoolRef _pool;
    BOOL _quality;
    CMTime _lastReference;
    NSInteger _multiplier;
    NSArray<NSNumber *> *_phases;
}

+ (BOOL)isSupported {
    return VTLowLatencyFrameInterpolationConfiguration.isSupported;
}

+ (BOOL)isQualitySupported {
    return VTFrameRateConversionConfiguration.isSupported;
}

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height quality:(BOOL)quality multiplier:(NSInteger)multiplier {
    self = [super init];
    if (!self || multiplier < 2 || multiplier > 8) return nil;
    _multiplier = multiplier;
    _quality = quality;
    NSMutableArray<NSNumber *> *phases = [NSMutableArray array];
    for (NSInteger i = 1; i < multiplier; i++) [phases addObject:@((double)i / multiplier)];
    _phases = [phases copy];
    _lastReference = kCMTimeInvalid;
    id<VTFrameProcessorConfiguration> configuration;
    NSDictionary *destinationAttributes;
    if (_quality) {
        VTFrameRateConversionConfiguration *frc =
            [[VTFrameRateConversionConfiguration alloc] initWithFrameWidth:width
                frameHeight:height usePrecomputedFlow:NO
                qualityPrioritization:VTFrameRateConversionConfigurationQualityPrioritizationQuality
                revision:VTFrameRateConversionConfiguration.defaultRevision];
        configuration = frc;
        destinationAttributes = frc.destinationPixelBufferAttributes;
    } else {
        VTLowLatencyFrameInterpolationConfiguration *lowLatency =
            [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:width
                frameHeight:height numberOfInterpolatedFrames:multiplier == 4 ? 2 : 1];
        configuration = lowLatency;
        destinationAttributes = lowLatency.destinationPixelBufferAttributes;
    }
    if (!configuration || !destinationAttributes) return nil;
    _processor = [VTFrameProcessor new];
    if (![_processor startSessionWithConfiguration:configuration error:NULL]) {
        _processor = nil;
        return nil;
    }
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
        (__bridge CFDictionaryRef)destinationAttributes, &_pool);
    return result == kCVReturnSuccess ? self : nil;
}

- (void)dealloc {
    [_processor endSession];
    if (_pool) CVPixelBufferPoolRelease(_pool);
}

- (NSArray<VTFrameProcessorFrame *> *)interpolatePrevious:(CVPixelBufferRef)previous
                                              previousTime:(CMTime)previousTime
                                                   current:(CVPixelBufferRef)current
                                               currentTime:(CMTime)currentTime {
    VTFrameProcessorFrame *before = [[VTFrameProcessorFrame alloc] initWithBuffer:previous
                                                               presentationTimeStamp:previousTime];
    VTFrameProcessorFrame *after = [[VTFrameProcessorFrame alloc] initWithBuffer:current
                                                              presentationTimeStamp:currentTime];
    if (!before || !after) return nil;
    NSMutableArray<VTFrameProcessorFrame *> *destinations = [NSMutableArray array];
    CMTime interval = CMTimeSubtract(currentTime, previousTime);
    CMTime lastPTS = previousTime;
    for (NSInteger index = 1; index < _multiplier; index++) {
        CMTime timestamp = CMTimeAdd(previousTime, CMTimeMultiplyByRatio(interval, (int32_t)index, (int32_t)_multiplier));
        if (CMTimeCompare(lastPTS, timestamp) >= 0 || CMTimeCompare(timestamp, currentTime) >= 0) return nil;
        CVPixelBufferRef result = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &result) != kCVReturnSuccess) return nil;
        CVBufferPropagateAttachments(previous, result);
        VTFrameProcessorFrame *frame = [[VTFrameProcessorFrame alloc] initWithBuffer:result presentationTimeStamp:timestamp];
        CVPixelBufferRelease(result);
        if (!frame) return nil;
        [destinations addObject:frame];
        lastPTS = timestamp;
    }
    id<VTFrameProcessorParameters> parameters;
    if (_quality) {
        VTFrameRateConversionParametersSubmissionMode mode =
            CMTimeCompare(_lastReference, previousTime) == 0
            ? VTFrameRateConversionParametersSubmissionModeSequential
            : VTFrameRateConversionParametersSubmissionModeRandom;
        parameters = [[VTFrameRateConversionParameters alloc] initWithSourceFrame:before
            nextFrame:after opticalFlow:nil interpolationPhase:_phases
            submissionMode:mode destinationFrames:destinations];
    } else {
        parameters = [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:after
            previousFrame:before interpolationPhase:_phases destinationFrames:destinations];
    }
    if (!parameters || ![_processor processWithParameters:parameters error:NULL]) return nil;
    _lastReference = currentTime;
    return destinations;
}
@end

@implementation VeyraDenoiser {
    VTFrameProcessor *_processor;
    VTFrameProcessorFrame *_prior;
    CVPixelBufferPoolRef _pool;
    CVPixelBufferPoolRef _inputPool;
    VTPixelTransferSessionRef _transfer;
    NSDictionary *_inputAttributes;
    OSType _format;
    float _strength;
    BOOL _reset;
}

+ (BOOL)isSupported {
    return VTTemporalNoiseFilterConfiguration.isSupported;
}

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height format:(OSType)format strength:(float)strength {
    self = [super init];
    if (!self) return nil;
    VTTemporalNoiseFilterConfiguration *configuration = [[VTTemporalNoiseFilterConfiguration alloc]
        initWithFrameWidth:width frameHeight:height sourcePixelFormat:format];
    if (!configuration || configuration.previousFrameCount < 1) return nil;
    _processor = [VTFrameProcessor new];
    if (![_processor startSessionWithConfiguration:configuration error:NULL]) {
        _processor = nil;
        return nil;
    }
    _strength = strength;
    _format = format;
    _inputAttributes = configuration.sourcePixelBufferAttributes;
    _reset = YES;
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
        (__bridge CFDictionaryRef)configuration.destinationPixelBufferAttributes, &_pool);
    return result == kCVReturnSuccess ? self : nil;
}

- (void)dealloc {
    [_processor endSession];
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_inputPool) CVPixelBufferPoolRelease(_inputPool);
    if (_transfer) CFRelease(_transfer);
}

- (void)reset {
    _prior = nil;
    _reset = YES;
}

- (CVPixelBufferRef)prepareInput:(CVPixelBufferRef)buffer {
    if (CVPixelBufferGetPixelFormatType(buffer) == _format) return CVPixelBufferRetain(buffer);
    if (!_inputPool) {
        NSMutableDictionary *attrs = [_inputAttributes mutableCopy];
        attrs[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey] = @(_format);
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_inputPool) != kCVReturnSuccess)
            return NULL;
    }
    if (!_transfer && VTPixelTransferSessionCreate(NULL, &_transfer) != noErr) return NULL;
    CVPixelBufferRef result = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _inputPool, &result) != kCVReturnSuccess) return NULL;
    CVBufferPropagateAttachments(buffer, result);
    if (VTPixelTransferSessionTransferImage(_transfer, buffer, result) == noErr) return result;
    CVPixelBufferRelease(result);
    return NULL;
}

- (CVPixelBufferRef)filter:(CVPixelBufferRef)buffer time:(CMTime)time {
    VTFrameProcessorFrame *now = [[VTFrameProcessorFrame alloc] initWithBuffer:buffer presentationTimeStamp:time];
    if (!now) return NULL;
    VTFrameProcessorFrame *prior = _prior;
    _prior = now;
    if (!prior) return NULL;
    CVPixelBufferRef result = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &result) != kCVReturnSuccess) return NULL;
    CVBufferPropagateAttachments(buffer, result);
    VTFrameProcessorFrame *dst = [[VTFrameProcessorFrame alloc] initWithBuffer:result presentationTimeStamp:time];
    VTTemporalNoiseFilterParameters *parameters = [[VTTemporalNoiseFilterParameters alloc] initWithSourceFrame:now
        nextFrames:@[] previousFrames:@[prior] destinationFrame:dst filterStrength:_strength hasDiscontinuity:_reset];
    if (!parameters || ![_processor processWithParameters:parameters error:NULL]) {
        CVPixelBufferRelease(result);
        _reset = YES;
        return NULL;
    }
    _reset = NO;
    return result;
}
@end
