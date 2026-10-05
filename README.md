# Paylo Flutter SDK

Accept payments, manage subscriptions, and show remotely configured native paywalls — without app store fees.

## Install

```yaml
# pubspec.yaml
dependencies:
  paylo:
    git:
      url: https://github.com/ssid131133-star/paylo-flutter.git
      ref: v0.9.0   # pin a release — see tags for the latest
```

Already installed without a `ref`? Your `pubspec.lock` froze an old commit — run `flutter pub upgrade paylo` to get the latest.

### Environments

The client defaults to the production API. For staging or self-hosted deployments, pass `baseUrl`:

```dart
final paylo = Paylo('pk_test_...', baseUrl: 'https://your-staging-api.example.com');
```

Use your **publishable** key (`pk_test_…` / `pk_live_…`) in the app — never the secret `sk_` key (Dashboard → Settings → API keys).

## Quick start — 3 lines

```dart
import 'package:paylo/paylo.dart';
import 'package:paylo/paylo_paywall.dart';

// 1 — in main(). That's the whole setup: the API key alone
//     identifies your account; a stable anonymous customer id is
//     created and persisted on the device; your plans preload.
await Paylo.configure('pk_test_...');

// 2 — show the paywall (server decides which one and whether,
//     from your dashboard targeting rules)
await PayloPaywall.showIfNeeded(context, placement: 'onboarding');

// 3 — gate features
if (await Paylo.hasEntitlement('pro')) { /* unlock */ }
```

At login, attach the history to your real user id (purchases, trials and
paywall stats are merged server-side — nothing is lost):

```dart
await Paylo.identify(user.id);   // and Paylo.logOut() at sign-out
```

### The "my subscription" page — one widget

```dart
Scaffold(body: PayloAccountView())
```

Renders the right thing by itself: active subscription → plan, price,
renewal (or trial-end) date and a **Manage subscription** button opening
the Stripe portal; lifetime purchase → no manage button; not subscribed
→ your paywall, ready to convert.

### Paywalls — one line, configured remotely

```dart
await PayloPaywall.showIfNeeded(context,
  placement: 'onboarding',                 // optional — maps to dashboard rules
  attributes: {'source': 'instagram'});    // optional — for audience targeting
```

Publish a new design from the dashboard and the app shows it on next launch — no release, no store review. Impressions, dismissals, and checkout opens are tracked automatically (they power the dashboard analytics and frequency caps). Texts are localized from the device locale when translations are configured.

### Embedded in a page (not a modal)

```dart
// Drop it in a Scaffold body — it loads itself and renders nothing
// if the server says nothing should be shown.
Scaffold(body: PayloPaywall.inline(placement: 'subscription_page'))
```

### From your own pricing UI

```dart
// User tapped "Pro" in your custom list? Open the paywall with that
// plan pre-selected:
await PayloPaywall.showIfNeeded(context,
  preselectedPlanSlug: 'pro_monthly');

// Or skip the paywall entirely and go straight to checkout:
await Paylo.instance.subscribe(
  planId: 'pro_monthly', customerId: Paylo.customerId);
```

### Manage / cancel a subscription

```dart
final status = await paylo.customerStatus(user.id);
final sub = status.activeSubscription;
if (sub != null) {
  // Opens the Stripe customer portal (cancel, update card…)
  await paylo.openPortal(sub.id, returnUrl: 'https://yourapp.com/account');
}
```

Lower-level building blocks if you want manual control: `paylo.resolvePaywall(...)` (all named parameters), `paylo.getPaywall(devId)`, `paylo.getPaywalls(devId)`, `paylo.logPaywallEvent(...)`, and `PayloPaywall.show(...)` — which accepts a nullable paywall and simply does nothing when it's null.

### Subscriptions

```dart
// Opens the branded checkout in the browser
final sub = await paylo.subscribe(planId: 'pro_monthly', customerId: user.id);

// Gate premium features
final status = await paylo.customerStatus(user.id);
if (status.hasActiveSubscription) { /* unlock */ }
```

### One-time payments

```dart
final session = await paylo.checkout(
  productName: 'Lifetime Access',
  amount: 4999, // cents
  description: 'Unlock all features forever',
);
final result = await paylo.waitForPayment(session.id);
if (result.isCompleted) { /* success */ }
```

## API reference

Full REST API docs: [README at the repo root](../../README.md) or https://paylo-six.vercel.app/docs
