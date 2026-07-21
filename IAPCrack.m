#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>
#import <UIKit/UIKit.h>

static NSString * const kPro = @"com.maxpod.pro_lifetime";
static NSString * const kUltimate = @"com.maxpod.ultimate_lifetime";

// ── NSUserDefaults hooks ─────────────────────────────────────

static id (*orig_UD_obj)(id, SEL, id);
static id (*orig_UD_data)(id, SEL, id);
static void (*orig_UD_set)(id, SEL, id, id);
static void (*orig_UD_rm)(id, SEL, id);
static id (*orig_UD_bool)(id, SEL, id);

static id hook_UD_obj(id self, SEL _cmd, id key) {
    if ([key isEqual:@"maxpod.purchase.verified_product_ids.v1"])
        return @[kPro, kUltimate];
    if ([key isEqual:@"maxpod.purchase.verified_at.v1"])
        return [NSDate date];
    return orig_UD_obj ? orig_UD_obj(self, _cmd, key) : nil;
}

static id hook_UD_data(id self, SEL _cmd, id key) {
    id cached = orig_UD_data ? orig_UD_data(self, _cmd, key) : nil;
    if (cached) return cached;
    // Prevent nil return which triggers re-sync
    if ([key isEqual:@"maxpod.purchase.entitlement_checkpoints.v2"])
        return [@"{\"v\":2}" dataUsingEncoding:NSUTF8StringEncoding];
    if ([key isEqual:@"maxpod.purchase.active_store_identity.v1"])
        return [@"{\"id\":\"store\"}" dataUsingEncoding:NSUTF8StringEncoding];
    return nil;
}

static void hook_UD_set(id self, SEL _cmd, id obj, id key) {
    if ([key hasPrefix:@"maxpod.purchase."] || [key hasPrefix:@"maxpod.purchase_preview."])
        return;
    if (orig_UD_set) orig_UD_set(self, _cmd, obj, key);
}

static void hook_UD_rm(id self, SEL _cmd, id key) {
    if ([key hasPrefix:@"maxpod.purchase."] || [key hasPrefix:@"maxpod.purchase_preview."])
        return;
    if (orig_UD_rm) orig_UD_rm(self, _cmd, key);
}

static id hook_UD_bool(id self, SEL _cmd, id key) {
    if ([key isEqual:@"unlockedUltimate"]) return @YES;
    return orig_UD_bool ? orig_UD_bool(self, _cmd, key) : nil;
}

// ── Receipt URL hook ─────────────────────────────────────────

static NSURL * (*orig_bundle_receiptURL)(id, SEL);

static NSURL *hook_receiptURL(id self, SEL _cmd) {
    // Return nil → app falls back to local cache, not server check
    return nil;
}

// ── SKPaymentQueue hooks ─────────────────────────────────────

@interface SKPaymentQueue (IAP)
- (void)_simulate:(SKPayment *)payment;
@end

static void (*orig_SKPQ_add)(id, SEL, id);

static void hook_SKPQ_addPayment(id self, SEL _cmd, SKPayment *payment) {
    NSString *pid = payment.productIdentifier;
    if ([pid isEqualToString:kPro] || [pid isEqualToString:kUltimate]) {
        [self _simulate:payment];
        return;
    }
    if (orig_SKPQ_add) orig_SKPQ_add(self, _cmd, payment);
}

@implementation SKPaymentQueue (IAP)
- (void)_simulate:(SKPayment *)payment {
    // Use KVC on a freshly allocated transaction
    id tx = class_createInstance(objc_getClass("SKPaymentTransaction"), 0);
    @try {
        [tx setValue:payment forKey:@"payment"];

        NSString *txID = [NSString stringWithFormat:@"%010ld%06d",
                          (long)time(NULL), arc4random_uniform(999999)];
        [tx setValue:txID forKey:@"transactionIdentifier"];
        [tx setValue:[NSDate date] forKey:@"transactionDate"];
        [tx setValue:@(1) forKey:@"transactionState"]; // purchased

        // Notify all observers
        NSArray *obs = [self valueForKey:@"transactionObservers"] ?: @[];
        for (id o in obs) {
            @try {
                ((void(*)(id,SEL,id,id))objc_msgSend)(
                    o, sel_registerName("paymentQueue:updatedTransactions:"),
                    self, @[tx]);
            } @catch (NSException *e) {
                NSLog(@"[IAPCrack] notify err: %@", e);
            }
        }

        // Persist reinforced data
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:@[kPro, kUltimate] forKey:@"maxpod.purchase.verified_product_ids.v1"];
        [ud setObject:[NSDate date] forKey:@"maxpod.purchase.verified_at.v1"];
        [ud synchronize];
        NSLog(@"[IAPCrack] ✓ simulated %@", payment.productIdentifier);
    } @catch (NSException *e) {
        NSLog(@"[IAPCrack] KVC failed: %@ — falling through", e);
    }
}
@end

// ── Swizzle ──────────────────────────────────────────────────

static BOOL swizz(Class c, SEL s, IMP n, IMP *o) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) m = class_getClassMethod(c, s);
    if (!m) return NO;
    if (o) *o = method_getImplementation(m);
    method_setImplementation(m, n);
    return YES;
}

// ── Constructor ──────────────────────────────────────────────

__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        NSLog(@"[IAPCrack] v4 loaded");

        // 1. Seed all relevant defaults
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        NSDictionary *seed = @{
            @"maxpod.purchase.verified_product_ids.v1": @[kPro, kUltimate],
            @"maxpod.purchase.verified_at.v1": [NSDate date],
            @"unlockedUltimate": @YES,
            // Preview grant — permanent trial as fallback
            @"maxpod.purchase_preview.active_grant.v1": @{@"tier":@"ultimate",@"expires":@"2099-01-01"},
            @"maxpod.purchase_preview.consumed_kinds.v1": @[],
        };
        for (NSString *k in seed) {
            id v = seed[k];
            if (![u objectForKey:k]) [u setObject:v forKey:k];
        }
        [u synchronize];

        // 2. Hook NSUserDefaults
        swizz([NSUserDefaults class], @selector(objectForKey:),
              (IMP)hook_UD_obj, (IMP*)&orig_UD_obj);
        swizz([NSUserDefaults class], @selector(dataForKey:),
              (IMP)hook_UD_data, (IMP*)&orig_UD_data);
        swizz([NSUserDefaults class], @selector(setObject:forKey:),
              (IMP)hook_UD_set, (IMP*)&orig_UD_set);
        swizz([NSUserDefaults class], @selector(removeObjectForKey:),
              (IMP)hook_UD_rm, (IMP*)&orig_UD_rm);
        swizz([NSUserDefaults class], @selector(boolForKey:),
              (IMP)hook_UD_bool, (IMP*)&orig_UD_bool);

        // 3. Hook receipt URL — force app to skip server receipt check
        swizz([NSBundle class], @selector(appStoreReceiptURL),
              (IMP)hook_receiptURL, (IMP*)&orig_bundle_receiptURL);

        // 4. Hook SKPaymentQueue (delayed for safety)
        dispatch_async(dispatch_get_main_queue(), ^{
            Class pq = objc_getClass("SKPaymentQueue");
            if (pq) {
                swizz(pq, @selector(addPayment:),
                      (IMP)hook_SKPQ_addPayment, (IMP*)&orig_SKPQ_add);
                NSLog(@"[IAPCrack] SKPaymentQueue hooked");
            }
        });

        // 5. Repeated re-seed to fight re-verification cycles
        for (int d = 2; d <= 10; d++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                [ud setObject:@[kPro, kUltimate]
                       forKey:@"maxpod.purchase.verified_product_ids.v1"];
                [ud setObject:[NSDate date]
                       forKey:@"maxpod.purchase.verified_at.v1"];
                [ud setBool:YES forKey:@"unlockedUltimate"];
                [ud synchronize];
            });
        }
    }
}
