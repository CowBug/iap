#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>

static NSString * const kProLifetime = @"com.maxpod.pro_lifetime";
static NSString * const kUltimateLifetime = @"com.maxpod.ultimate_lifetime";
static NSString * const kUltimateUpgrade = @"com.maxpod.ultimate_upgrade_from_pro";

// ── Runtime method hunting ───────────────────────────────────

static void logAllMethods(Class cls, const char *label) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSLog(@"[IAPCrack] %s method: %@", label, NSStringFromSelector(sel));
    }
    free(methods);
}

static IMP findMethod(Class cls, NSString *selPrefix) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if ([name rangeOfString:selPrefix options:NSCaseInsensitiveSearch].location != NSNotFound) {
            IMP imp = method_getImplementation(methods[i]);
            free(methods);
            NSLog(@"[IAPCrack] found %@ → %p", name, imp);
            return imp;
        }
    }
    free(methods);
    return NULL;
}

// ── NSUserDefaults hooks ─────────────────────────────────────

static id (*orig_UD_object)(id, SEL, id);
static id (*orig_UD_data)(id, SEL, id);
static void (*orig_UD_setObject)(id, SEL, id, id);
static void (*orig_UD_removeObject)(id, SEL, id);

static id hook_UD_objectForKey(id self, SEL _cmd, id key) {
    if ([key isEqual:@"maxpod.purchase.verified_product_ids.v1"]) {
        return @[kProLifetime, kUltimateLifetime];
    }
    if ([key isEqual:@"maxpod.purchase.verified_at.v1"]) {
        return [NSDate date];
    }
    return orig_UD_object ? orig_UD_object(self, _cmd, key) : nil;
}

static id hook_UD_dataForKey(id self, SEL _cmd, id key) {
    // Never return nil for checkpoints or identity - forces app to
    // use cached verified_product_ids without re-verification
    if ([key isEqual:@"maxpod.purchase.entitlement_checkpoints.v2"]) {
        id cached = orig_UD_data ? orig_UD_data(self, _cmd, key) : nil;
        if (cached) return cached;
        // Return a non-nil placeholder so the app doesn't trigger full re-sync
        return [@"{\"v\":2}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([key isEqual:@"maxpod.purchase.active_store_identity.v1"]) {
        id cached = orig_UD_data ? orig_UD_data(self, _cmd, key) : nil;
        if (cached) return cached;
        return [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    return orig_UD_data ? orig_UD_data(self, _cmd, key) : nil;
}

static void hook_UD_setObject_forKey(id self, SEL _cmd, id obj, id key) {
    if ([key isEqual:@"maxpod.purchase.verified_product_ids.v1"] ||
        [key isEqual:@"maxpod.purchase.verified_at.v1"] ||
        [key isEqual:@"maxpod.purchase.pending_approval_product_id.v1"]) {
        return;
    }
    if (orig_UD_setObject) orig_UD_setObject(self, _cmd, obj, key);
}

static void hook_UD_removeObjectForKey(id self, SEL _cmd, id key) {
    // Block removal of purchase-related keys
    if ([key hasPrefix:@"maxpod.purchase."] ||
        [key hasPrefix:@"maxpod.purchase_preview."]) {
        return;
    }
    if (orig_UD_removeObject) orig_UD_removeObject(self, _cmd, key);
}

// ── Purchase simulation category (forward decl) ──────────────

@interface SKPaymentQueue (IAPCrack)
- (void)_simulatePurchaseSuccess:(SKPayment *)payment;
@end

// ── SKPaymentQueue hook ──────────────────────────────────────

static void (*orig_SKPQ_add)(id, SEL, id);

static void hook_SKPQ_addPayment(id self, SEL _cmd, SKPayment *payment) {
    NSString *pid = payment.productIdentifier;
    if ([pid isEqualToString:kProLifetime] ||
        [pid isEqualToString:kUltimateLifetime] ||
        [pid isEqualToString:kUltimateUpgrade]) {
        // Simulate purchase success to trigger the app's purchase flow
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [self _simulatePurchaseSuccess:payment];
        });
        return;
    }
    if (orig_SKPQ_add) orig_SKPQ_add(self, _cmd, payment);
}

// ── Purchase simulation category ─────────────────────────────

@interface SKPaymentQueue (IAPCrack)
- (void)_simulatePurchaseSuccess:(SKPayment *)payment;
@end

@implementation SKPaymentQueue (IAPCrack)
- (void)_simulatePurchaseSuccess:(SKPayment *)payment {
    Class txCls = objc_getClass("SKPaymentTransaction");
    if (!txCls) return;

    // Try to create a transaction via KVC
    id tx = class_createInstance(txCls, 0);
    @try {
        [tx setValue:payment forKey:@"payment"];
        [tx setValue:[NSString stringWithFormat:@"%010ld000000", (long)time(NULL)]
               forKey:@"transactionIdentifier"];
        [tx setValue:[NSDate date] forKey:@"transactionDate"];
        // transactionState = 1 = SKPaymentTransactionStatePurchased
        [tx setValue:@(1) forKey:@"transactionState"];

        NSArray *obs = [self valueForKey:@"transactionObservers"] ?: @[];
        for (id observer in obs) {
            @try {
                ((void(*)(id,SEL,id,id))objc_msgSend)(
                    observer,
                    sel_registerName("paymentQueue:updatedTransactions:"),
                    self,
                    @[tx]
                );
            } @catch (NSException *e) {
                NSLog(@"[IAPCrack] observer notify failed: %@", e);
            }
        }
        // Persist in defaults
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:@[kProLifetime, kUltimateLifetime]
               forKey:@"maxpod.purchase.verified_product_ids.v1"];
        [ud setObject:[NSDate date] forKey:@"maxpod.purchase.verified_at.v1"];
        [ud synchronize];
        NSLog(@"[IAPCrack] ✓ simulated purchase: %@", payment.productIdentifier);
    } @catch (NSException *e) {
        NSLog(@"[IAPCrack] simulate failed: %@", e);
    }
}
@end

// ── Swizzle helper ───────────────────────────────────────────

static BOOL swizzle(Class cls, SEL sel, IMP new, IMP *old) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) m = class_getClassMethod(cls, sel);
    if (!m) return NO;
    if (old) *old = method_getImplementation(m);
    method_setImplementation(m, new);
    return YES;
}

// ── Hook StoreKitPurchaseService ─────────────────────────────

static void hookPurchaseService(void) {
    // Try both ObjC mangled names
    Class psvc = objc_getClass("_TtC9MaxPodApp23StoreKitPurchaseService");
    if (!psvc) {
        psvc = NSClassFromString(@"MaxPodApp.StoreKitPurchaseService");
    }
    if (!psvc) {
        NSLog(@"[IAPCrack] StoreKitPurchaseService not found yet, will retry...");
        return;
    }
    NSLog(@"[IAPCrack] StoreKitPurchaseService = %@", psvc);
    logAllMethods(psvc, "StoreKitPurchaseService");

    // Hook purchase access / tier check methods
    // Common Swift→ObjC selector patterns for purchase services
    SEL candidates[] = {
        NSSelectorFromString(@"purchaseAccess"),
        NSSelectorFromString(@"purchaseAccessWithContext:"),
        NSSelectorFromString(@"purchaseAccessWith:"),
        NSSelectorFromString(@"purchaseTier"),
        NSSelectorFromString(@"effectiveTier"),
        NSSelectorFromString(@"currentTier"),
        NSSelectorFromString(@"syncPurchaseState"),
        NSSelectorFromString(@"syncPurchaseStateWithCompletionHandler:"),
        NSSelectorFromString(@"isPro"),
        NSSelectorFromString(@"isUltimate"),
        NSSelectorFromString(@"checkEntitlements"),
        NSSelectorFromString(@"refreshEntitlements"),
        NSSelectorFromString(@"verifyEntitlements"),
        NSSelectorFromString(@"entitledFeatures"),
        NSSelectorFromString(@"activePurchases"),
    };

    for (size_t i = 0; i < sizeof(candidates)/sizeof(candidates[0]); i++) {
        Method m = class_getInstanceMethod(psvc, candidates[i]);
        if (!m) m = class_getClassMethod(psvc, candidates[i]);
        if (m) {
            NSLog(@"[IAPCrack] found hook target: %@", NSStringFromSelector(candidates[i]));
        }
    }
}

// ── Constructor ──────────────────────────────────────────────

__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        NSLog(@"[IAPCrack] loaded");

        // 1. Seed UserDefaults
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:@[kProLifetime, kUltimateLifetime]
               forKey:@"maxpod.purchase.verified_product_ids.v1"];
        [ud setObject:[NSDate date] forKey:@"maxpod.purchase.verified_at.v1"];
        [ud removeObjectForKey:@"maxpod.purchase.pending_approval_product_id.v1"];
        [ud synchronize];

        // 2. Hook NSUserDefaults
        swizzle([NSUserDefaults class], @selector(objectForKey:),
                (IMP)hook_UD_objectForKey, (IMP*)&orig_UD_object);
        swizzle([NSUserDefaults class], @selector(dataForKey:),
                (IMP)hook_UD_dataForKey, (IMP*)&orig_UD_data);
        swizzle([NSUserDefaults class], @selector(setObject:forKey:),
                (IMP)hook_UD_setObject_forKey, (IMP*)&orig_UD_setObject);
        swizzle([NSUserDefaults class], @selector(removeObjectForKey:),
                (IMP)hook_UD_removeObjectForKey, (IMP*)&orig_UD_removeObject);

        // 3. Hook SKPaymentQueue + find StoreKitPurchaseService (delayed)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            Class pq = objc_getClass("SKPaymentQueue");
            if (pq) {
                swizzle(pq, @selector(addPayment:),
                        (IMP)hook_SKPQ_addPayment, (IMP*)&orig_SKPQ_add);
                NSLog(@"[IAPCrack] SKPaymentQueue hooked");
            }
            hookPurchaseService();
        });

        // 4. Re-seed defaults periodically to fight re-verification
        // The app re-checks Transaction.currentEntitlements and may
        // clear our data; we reinforce every few seconds
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
            [u setObject:@[kProLifetime, kUltimateLifetime]
                  forKey:@"maxpod.purchase.verified_product_ids.v1"];
            [u setObject:[NSDate date] forKey:@"maxpod.purchase.verified_at.v1"];
            [u synchronize];
            NSLog(@"[IAPCrack] reinforced seed");
        });
    }
}
