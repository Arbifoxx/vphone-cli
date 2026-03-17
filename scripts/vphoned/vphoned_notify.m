/*
 * vphoned_notify — System notification and power state commands.
 *
 * low_power_mode: sets LowPowerMode on IOPMrootDomain via IOKit, which is the
 *   authoritative path powerd responds to. The RootDomainUserClient entitlement
 *   in entitlements.plist grants the required IOKit access.
 *
 *   IORegistryEntryFromPath / IORegistryEntrySetCFProperty are marked
 *   API_UNAVAILABLE(ios) in the SDK headers but are present at runtime.
 *   We resolve them via dlsym(RTLD_DEFAULT) to bypass the header restriction.
 *
 * darwin_notify: posts an arbitrary Darwin notification via notify_post().
 */

#import "vphoned_notify.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <notify.h>

// IOKit types — defined here to avoid pulling in API_UNAVAILABLE declarations.
typedef mach_port_t io_object_t;
typedef io_object_t io_registry_entry_t;
#define IO_OBJECT_NULL ((io_object_t)MACH_PORT_NULL)

typedef io_registry_entry_t (*IORegistryEntryFromPath_fn)(mach_port_t,
                                                          const char *);
typedef kern_return_t (*IORegistryEntrySetCFProperty_fn)(io_registry_entry_t,
                                                         CFStringRef,
                                                         CFTypeRef);
typedef kern_return_t (*IOObjectRelease_fn)(io_object_t);

typedef io_object_t (*IOServiceGetMatchingService_fn)(mach_port_t,
                                                      CFDictionaryRef);
typedef CFMutableDictionaryRef (*IOServiceMatching_fn)(const char *);
typedef kern_return_t (*IOServiceOpen_fn)(io_object_t, mach_port_t, uint32_t,
                                          io_object_t *);
typedef kern_return_t (*IOConnectSetCFProperty_fn)(io_object_t, CFStringRef,
                                                   CFTypeRef);
typedef kern_return_t (*IOServiceClose_fn)(io_object_t);

// Attempt 1: IOConnectSetCFProperty via RootDomainUserClient.
// IORegistryEntrySetCFProperty is blocked (kIOReturnNotPermitted) because it
// writes the registry directly. Going through a user-client connection is the
// entitled path — that is what RootDomainUserClient in the entitlements allows.
static BOOL lpm_try_iokit_userclient(BOOL enabled) {
  IOServiceGetMatchingService_fn get_matching =
      (IOServiceGetMatchingService_fn)dlsym(RTLD_DEFAULT,
                                            "IOServiceGetMatchingService");
  IOServiceMatching_fn svc_matching =
      (IOServiceMatching_fn)dlsym(RTLD_DEFAULT, "IOServiceMatching");
  IOServiceOpen_fn svc_open =
      (IOServiceOpen_fn)dlsym(RTLD_DEFAULT, "IOServiceOpen");
  IOConnectSetCFProperty_fn connect_set =
      (IOConnectSetCFProperty_fn)dlsym(RTLD_DEFAULT, "IOConnectSetCFProperty");
  IOServiceClose_fn svc_close =
      (IOServiceClose_fn)dlsym(RTLD_DEFAULT, "IOServiceClose");
  IOObjectRelease_fn obj_release =
      (IOObjectRelease_fn)dlsym(RTLD_DEFAULT, "IOObjectRelease");

  if (!get_matching || !svc_matching || !svc_open || !connect_set ||
      !svc_close || !obj_release) {
    NSLog(@"vphoned: LPM[iokit]: missing symbols");
    return NO;
  }

  CFMutableDictionaryRef matching = svc_matching("IOPMrootDomain");
  if (!matching) {
    NSLog(@"vphoned: LPM[iokit]: IOServiceMatching returned null");
    return NO;
  }
  io_object_t service = get_matching(MACH_PORT_NULL, matching);
  if (service == IO_OBJECT_NULL) {
    NSLog(@"vphoned: LPM[iokit]: IOPMrootDomain service not found");
    return NO;
  }

  io_object_t connect = IO_OBJECT_NULL;
  kern_return_t kr = svc_open(service, mach_task_self(), 0, &connect);
  obj_release(service);
  if (kr != KERN_SUCCESS) {
    NSLog(@"vphoned: LPM[iokit]: IOServiceOpen -> kr=0x%x (FAILED)", kr);
    return NO;
  }

  kr = connect_set(connect, CFSTR("LowPowerMode"),
                   enabled ? kCFBooleanTrue : kCFBooleanFalse);
  svc_close(connect);
  NSLog(@"vphoned: LPM[iokit]: IOConnectSetCFProperty(LowPowerMode, %d) -> kr=0x%x (%s)",
        (int)enabled, kr, kr == KERN_SUCCESS ? "ok" : "FAILED");
  return (kr == KERN_SUCCESS);
}

// Attempt 2: notify_set_state + notify_post.
// All registrations for the same notification name share one state value, so
// setting it here updates what NSProcessInfo and SpringBoard read via
// notify_get_state. This is what powerd does internally.
static BOOL lpm_try_notify(BOOL enabled) {
  int token = 0;
  int nr = notify_register_check("com.apple.system.lowpowermode", &token);
  if (nr != NOTIFY_STATUS_OK) {
    NSLog(@"vphoned: LPM[notify]: notify_register_check failed: %d", nr);
    return NO;
  }
  notify_set_state(token, enabled ? 1 : 0);
  int pr = notify_post("com.apple.system.lowpowermode");
  notify_cancel(token);
  NSLog(@"vphoned: LPM[notify]: notify_set_state(%d) + notify_post -> %s",
        (int)enabled, pr == NOTIFY_STATUS_OK ? "ok" : "FAILED");
  return (pr == NOTIFY_STATUS_OK);
}

NSDictionary *vp_handle_notify_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  // -- low_power_mode --
  if ([type isEqualToString:@"low_power_mode"]) {
    BOOL enabled = [msg[@"enabled"] boolValue];
    BOOL iokit_ok = lpm_try_iokit_userclient(enabled);
    BOOL notify_ok = lpm_try_notify(enabled);
    NSLog(@"vphoned: LPM: iokit=%s notify=%s",
          iokit_ok ? "ok" : "fail", notify_ok ? "ok" : "fail");
    NSMutableDictionary *r = vp_make_response(@"low_power_mode", reqId);
    r[@"ok"] = @(iokit_ok || notify_ok);
    return r;
  }

  // -- darwin_notify --
  if ([type isEqualToString:@"darwin_notify"]) {
    NSString *name = msg[@"name"];
    if (!name || name.length == 0) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing notification name";
      return r;
    }
    int result = notify_post(name.UTF8String);
    NSMutableDictionary *r = vp_make_response(@"darwin_notify", reqId);
    r[@"ok"] = @(result == NOTIFY_STATUS_OK);
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown notify command: %@", type];
  return r;
}
