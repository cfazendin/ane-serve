#ifndef CIOREPORT_H
#define CIOREPORT_H

// Declarations for macOS's private libIOReport, matching the signatures in common use by
// open-source power tools. Apple does not document this API and may change it. Functions
// named Create or Copy return retained objects; Get functions return unretained ones.

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;

CF_ASSUME_NONNULL_BEGIN

CFDictionaryRef _Nullable IOReportCopyChannelsInGroup(CFStringRef _Nullable group, CFStringRef _Nullable subgroup,
                                                      uint64_t a, uint64_t b, uint64_t c);
void IOReportMergeChannels(CFMutableDictionaryRef destination, CFDictionaryRef source, CFTypeRef _Nullable unused);
IOReportSubscriptionRef _Nullable IOReportCreateSubscription(void * _Nullable unused, CFMutableDictionaryRef desiredChannels,
                                                             CFMutableDictionaryRef _Nullable * _Nullable subscribedChannels,
                                                             uint64_t channelID, CFTypeRef _Nullable options);
CFDictionaryRef _Nullable IOReportCreateSamples(IOReportSubscriptionRef subscription, CFMutableDictionaryRef subscribedChannels,
                                                CFTypeRef _Nullable unused);
CFDictionaryRef _Nullable IOReportCreateSamplesDelta(CFDictionaryRef first, CFDictionaryRef second, CFTypeRef _Nullable unused);

CFStringRef _Nullable IOReportChannelGetChannelName(CFDictionaryRef channel);
CFStringRef _Nullable IOReportChannelGetSubGroup(CFDictionaryRef channel);
CFStringRef _Nullable IOReportChannelGetUnitLabel(CFDictionaryRef channel);

int32_t IOReportStateGetCount(CFDictionaryRef channel);
CFStringRef _Nullable IOReportStateGetNameForIndex(CFDictionaryRef channel, int32_t index);
int64_t IOReportStateGetResidency(CFDictionaryRef channel, int32_t index);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);

CF_ASSUME_NONNULL_END

#endif
