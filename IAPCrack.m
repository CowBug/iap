#import <objc/runtime.h>
#import <Foundation/Foundation.h>

static NSString * const kPro = @"com.maxpod.pro_lifetime";
static NSString * const kUltimate = @"com.maxpod.ultimate_lifetime";

static id (*orig_obj)(id, SEL, id);
static void (*orig_set)(id, SEL, id, id);
static void (*orig_rm)(id, SEL, id);

static id hook_obj(id self, SEL _cmd, id key) {
    if ([key isEqual:@"maxpod.purchase.verified_product_ids.v1"])
        return @[kPro, kUltimate];
    if ([key isEqual:@"maxpod.purchase.verified_at.v1"])
        return [NSDate date];
    return orig_obj ? orig_obj(self, _cmd, key) : nil;
}

static void hook_set(id self, SEL _cmd, id obj, id key) {
    if ([key hasPrefix:@"maxpod.purchase."]) return;
    if (orig_set) orig_set(self, _cmd, obj, key);
}

static void hook_rm(id self, SEL _cmd, id key) {
    if ([key hasPrefix:@"maxpod.purchase."]) return;
    if (orig_rm) orig_rm(self, _cmd, key);
}

__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        [u setObject:@[kPro, kUltimate] forKey:@"maxpod.purchase.verified_product_ids.v1"];
        [u setObject:[NSDate date] forKey:@"maxpod.purchase.verified_at.v1"];
        [u synchronize];

        Class c = [NSUserDefaults class];
        Method m1 = class_getInstanceMethod(c, @selector(objectForKey:));
        if (m1) { orig_obj = method_getImplementation(m1); method_setImplementation(m1, (IMP)hook_obj); }
        Method m2 = class_getInstanceMethod(c, @selector(setObject:forKey:));
        if (m2) { orig_set = method_getImplementation(m2); method_setImplementation(m2, (IMP)hook_set); }
        Method m3 = class_getInstanceMethod(c, @selector(removeObjectForKey:));
        if (m3) { orig_rm = method_getImplementation(m3); method_setImplementation(m3, (IMP)hook_rm); }
    }
}
