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
await Paylo.configure('pk_test_...', baseUrl: 'https://your-staging-api.example.com');
```

## Before you start (Paylo dashboard)

1. **Publishable key** — copy `pk_test_…` from Settings → API keys. It's the only key that goes in an app; never ship the secret `sk_` key.
2. **Redirect URLs** — set a default Success and Cancel URL in Settings (a web page or your app's deep link, e.g. `myapp://paylo/success`). **Required**: the SDK doesn't pass its own, and checkouts fail with `success_url and cancel_url are required` until they're set.
3. **Plans** — create them in Payments (test mode), with the entitlements each one grants (e.g. `pro`).
4. **Paywall** — design one in Paywalls and **Publish** it.
5. **Test card** — `4242 4242 4242 4242`, any future date, any CVC.

Checkout opens in the device browser. When the customer comes back, read their access again (`Paylo.hasEntitlement`) — the subscription is active as soon as Stripe confirms the payment, usually within seconds.

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
// Opens the Stripe customer portal (cancel, update card, invoices).
// Returns false when there's nothing to manage (no subscription, or a
// lifetime purchase).
await Paylo.openManagement();
```

`PayloAccountView` already includes this button.

Lower-level building blocks if you want manual control: `paylo.resolvePaywall(...)` (all named parameters), `paylo.getPaywall(devId)`, `paylo.getPaywalls(devId)`, `paylo.logPaywallEvent(...)`, and `PayloPaywall.show(...)` — which accepts a nullable paywall and simply does nothing when it's null.

### Subscriptions (explicit API)

```dart
// Opens the branded checkout in the browser
final sub = await Paylo.instance.subscribe(planId: 'pro_monthly', customerId: Paylo.customerId);

// Gate premium features
final status = await Paylo.status();
if (status.hasEntitlement('pro')) { /* unlock */ }
```

Lifetime access is a plan with interval `one_time`, sold the same way — the customer then stays subscribed for good.

### One-time payments (purchases your server fulfils)

```dart
final session = await Paylo.instance.checkout(
  productName: '500 credits',
  amount: 499, // cents
);
final result = await Paylo.instance.waitForPayment(session.id);
if (result.isCompleted) { /* credit the user */ }
```

A payment session isn't tied to a customer and grants no entitlement — for unlocking features, sell a `one_time` plan instead (see above).

## API reference

Full docs and REST API reference: https://paylo-six.vercel.app/docs
