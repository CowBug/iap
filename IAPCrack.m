#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const kProLifetime = @"com.maxpod.pro_lifetime";
static NSString * const kUltimateLifetime = @"com.maxpod.ultimate_lifetime";
static NSString * const kUltimateUpgrade = @"com.maxpod.ultimate_upgrade_from_pro";

static NSArray *verifiedProducts(void) {
    return @[kProLifetime, kUltimateLifetime];
}

// ── NSUserDefaults hook ──────────────────────────────────────

static id (*orig_UD_object)(id, SEL, NSString*);
static id (*orig_UD_array)(id, SEL, NSString*);
static void (*orig_UD_setObject)(id, SEL, id, NSString*);

static id hook_UD_objectForKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:@"maxpod.purchase.verified_product_ids.v1"]) {
        return verifiedProducts();
    }
    if ([key isEqualToString:@"maxpod.purchase.verified_at.v1"]) {
        return [NSDate date];
    }
    return orig_UD_object(self, _cmd, key);
}

static id hook_UD_arrayForKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:@"maxpod.purchase.verified_product_ids.v1"]) {
        return verifiedProducts();
    }
    return orig_UD_array(self, _cmd, key);
}

static void hook_UD_setObject_forKey(id self, SEL _cmd, id obj, NSString *key) {
    if ([key isEqualToString:@"maxpod.purchase.verified_product_ids.v1"] ||
        [key isEqualToString:@"maxpod.purchase.verified_at.v1"] ||
        [key isEqualToString:@"maxpod.purchase.pending_approval_product_id.v1"]) {
        return; // block clear
    }
    orig_UD_setObject(self, _cmd, obj, key);
}

// ── SKPaymentQueue hook (just swallow purchases) ─────────────

static void (*orig_SKPQ_add)(id, SEL, id);

static void hook_SKPQ_addPayment(id self, SEL _cmd, id payment) {
    NSString *pid = ((id(*)(id,SEL))objc_msgSend)(payment,
                     sel_registerName("productIdentifier"));
    if ([pid isEqualToString:kProLifetime] ||
        [pid isEqualToString:kUltimateLifetime] ||
        [pid isEqualToString:kUltimateUpgrade]) {
        return; // silently swallow
    }
    orig_SKPQ_add(self, _cmd, payment);
}

// ── Safe swizzle helper ──────────────────────────────────────

static BOOL safeSwizzle(Class cls, SEL sel, IMP newImp, IMP *old) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        m = class_getClassMethod(cls, sel);
    }
    if (!m) return NO;
    *old = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

// ── Constructor ──────────────────────────────────────────────

__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        // Priority 1: seed UserDefaults before anything reads it
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:verifiedProducts() forKey:@"maxpod.purchase.verified_product_ids.v1"];
        [ud setObject:[NSDate date] forKey:@"maxpod.purchase.verified_at.v1"];
        [ud removeObjectForKey:@"maxpod.purchase.pending_approval_product_id.v1"];
        [ud synchronize];

        // Priority 2: hook NSUserDefaults reads
        safeSwizzle([NSUserDefaults class], @selector(objectForKey:),
                    (IMP)hook_UD_objectForKey, (IMP*)&orig_UD_object);
        safeSwizzle([NSUserDefaults class], @selector(arrayForKey:),
                    (IMP)hook_UD_arrayForKey, (IMP*)&orig_UD_array);
        safeSwizzle([NSUserDefaults class], @selector(setObject:forKey:),
                    (IMP)hook_UD_setObject_forKey, (IMP*)&orig_UD_setObject);

        // Priority 3: hook SKPaymentQueue after UIKit is ready
        // (StoreKit needs UIKit's runloop, so delay until main queue)
        dispatch_async(dispatch_get_main_queue(), ^{
            Class pq = objc_getClass("SKPaymentQueue");
            if (pq) {
                safeSwizzle(pq, @selector(addPayment:),
                            (IMP)hook_SKPQ_addPayment, (IMP*)&orig_SKPQ_add);
            }
        });
    }
}
