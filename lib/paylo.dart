library paylo;

import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Default API host. `api.paylo.dev` is not live yet — this points at the
/// current production deployment. Override with `baseUrl:` to target a
/// staging environment.
const String kPayloDefaultBaseUrl = 'https://paylo-production.up.railway.app';

class PayloConfig {
  final String apiKey;
  final String baseUrl;

  const PayloConfig({
    required this.apiKey,
    this.baseUrl = kPayloDefaultBaseUrl,
  });
}

class PayloException implements Exception {
  final String message;
  final int? statusCode;

  PayloException(this.message, {this.statusCode});

  @override
  String toString() => 'PayloException: $message (status: $statusCode)';
}

class CheckoutResult {
  final String id;
  final String url;
  final String status;

  CheckoutResult({required this.id, required this.url, required this.status});

  factory CheckoutResult.fromJson(Map<String, dynamic> json) {
    return CheckoutResult(
      id: json['id'] as String,
      url: json['url'] as String,
      status: json['status'] as String,
    );
  }
}

class SessionStatus {
  final String id;
  final String productName;
  final int amount;
  final String currency;
  final String status;

  SessionStatus({
    required this.id,
    required this.productName,
    required this.amount,
    required this.currency,
    required this.status,
  });

  bool get isCompleted => status == 'completed';

  factory SessionStatus.fromJson(Map<String, dynamic> json) {
    return SessionStatus(
      id: json['id'] as String,
      productName: json['product_name'] as String,
      amount: json['amount'] as int,
      currency: json['currency'] as String,
      status: json['status'] as String,
    );
  }
}

class SubscriptionResult {
  final String id;
  final String url;
  final String status;

  SubscriptionResult({required this.id, required this.url, required this.status});

  factory SubscriptionResult.fromJson(Map<String, dynamic> json) {
    return SubscriptionResult(
      id: json['id'] as String,
      url: json['url'] as String,
      status: json['status'] as String,
    );
  }
}

class SubscriptionStatus {
  final String id;
  final String customerId;
  final String? customerEmail;
  final String status;
  final PlanInfo plan;
  final DateTime? currentPeriodEnd;

  bool get isActive => status == 'active' || status == 'cancelling';

  SubscriptionStatus({
    required this.id,
    required this.customerId,
    this.customerEmail,
    required this.status,
    required this.plan,
    this.currentPeriodEnd,
  });

  factory SubscriptionStatus.fromJson(Map<String, dynamic> json) {
    return SubscriptionStatus(
      id: json['id'] as String,
      customerId: json['customer_id'] as String,
      customerEmail: json['customer_email']?.toString(),
      status: json['status'] as String,
      plan: PlanInfo.fromJson(json['plan'] as Map<String, dynamic>),
      currentPeriodEnd: json['current_period_end'] != null
          ? DateTime.parse(json['current_period_end'].toString())
          : null,
    );
  }
}

class PlanInfo {
  final String name;
  final int amount;
  final String currency;
  final String interval;

  PlanInfo({
    required this.name,
    required this.amount,
    required this.currency,
    required this.interval,
  });

  factory PlanInfo.fromJson(Map<String, dynamic> json) {
    return PlanInfo(
      name: json['name'] as String,
      amount: json['amount'] as int,
      currency: json['currency'] as String,
      interval: json['interval'] as String,
    );
  }
}

class ActivePlan {
  final String name;

  /// Stable plan id — matches a [Plan.slug]. Lets apps tell the active plan
  /// apart from the others in [Paylo.plans]. Null on older servers.
  final String? slug;
  final int? amount; // cents
  final String? currency;
  final String interval;
  final DateTime? currentPeriodEnd;

  /// When the free trial ends — null when not in a trial.
  final DateTime? trialEnd;

  ActivePlan({
    required this.name,
    this.slug,
    this.amount,
    this.currency,
    required this.interval,
    this.currentPeriodEnd,
    this.trialEnd,
  });

  factory ActivePlan.fromJson(Map<String, dynamic> json) {
    return ActivePlan(
      name: json['name'] as String,
      slug: json['slug']?.toString(),
      amount: json['amount'] as int?,
      currency: json['currency'] as String?,
      interval: json['interval'] as String,
      currentPeriodEnd: json['current_period_end'] != null
          ? DateTime.parse(json['current_period_end'].toString())
          : null,
      trialEnd: json['trial_end'] != null
          ? DateTime.parse(json['trial_end'].toString())
          : null,
    );
  }
}

/// One line of a customer's subscription history — enough to drive
/// management actions like [Paylo.openPortal].
class SubscriptionSummary {
  final String id;
  final String status;
  final String planName;
  final DateTime createdAt;

  SubscriptionSummary({
    required this.id,
    required this.status,
    required this.planName,
    required this.createdAt,
  });

  bool get isActive => status == 'active' || status == 'cancelling' || status == 'trialing';

  factory SubscriptionSummary.fromJson(Map<String, dynamic> json) {
    return SubscriptionSummary(
      id: json['id'] as String,
      status: json['status'] as String,
      planName: json['plan_name'] as String,
      createdAt: DateTime.parse(json['created_at'].toString()),
    );
  }
}

class CustomerStatus {
  final String customerId;
  final bool hasActiveSubscription;

  /// True when the current access comes from a free trial.
  final bool isTrial;

  /// Feature keys unlocked by the customer's plans (union across
  /// active/trialing subs) — configured per plan in the dashboard.
  final List<String> entitlements;

  /// False for one-time (lifetime) purchases — there is no Stripe
  /// subscription behind them, so the customer portal can't manage them.
  final bool canManage;
  final ActivePlan? activePlan;
  final List<SubscriptionSummary> subscriptions;

  /// A downgrade the customer already confirmed but that takes effect at the
  /// end of the current period. Null when no change is pending.
  final ScheduledChange? scheduledChange;

  CustomerStatus({
    required this.customerId,
    required this.hasActiveSubscription,
    this.isTrial = false,
    this.entitlements = const [],
    this.canManage = false,
    this.activePlan,
    this.subscriptions = const [],
    this.scheduledChange,
  });

  /// Gate features by capability instead of plan name:
  /// `if (status.hasEntitlement('pro')) { … }`
  bool hasEntitlement(String key) => entitlements.contains(key);

  /// The subscription to manage (cancel, change payment method…) —
  /// pass its id to [Paylo.openPortal].
  SubscriptionSummary? get activeSubscription =>
      subscriptions.cast<SubscriptionSummary?>().firstWhere((s) => s!.isActive, orElse: () => null);

  factory CustomerStatus.fromJson(Map<String, dynamic> json) {
    final ap = json['active_plan'];
    return CustomerStatus(
      customerId: json['customer_id'] as String,
      hasActiveSubscription: json['has_active_subscription'] as bool,
      isTrial: json['is_trial'] as bool? ?? false,
      entitlements: (json['entitlements'] as List? ?? []).cast<String>(),
      canManage: json['can_manage'] as bool? ?? false,
      activePlan: ap is Map<String, dynamic> ? ActivePlan.fromJson(ap) : null,
      subscriptions: (json['subscriptions'] as List? ?? [])
          .map((s) => SubscriptionSummary.fromJson(s as Map<String, dynamic>))
          .toList(),
      scheduledChange: json['scheduled_change'] is Map<String, dynamic>
          ? ScheduledChange.fromJson(json['scheduled_change'] as Map<String, dynamic>)
          : null,
    );
  }
}

class PaywallConfig {
  final String template;
  final String title;
  final String? subtitle;
  final List<String> features;
  final String ctaText;
  final String primaryColor; // hex, e.g. "#4F46E5"
  final String theme; // "dark" | "light"
  final List<String> planSlugs;
  final String? highlightPlanSlug;
  final String? badgeText;
  final String? footerText;
  final bool showCloseButton;
  final String? imageUrl;
  final String titleAlign; // "left" | "center"
  final String? secondaryButtonText;
  final String? backgroundColor; // hex, overrides theme background
  final String? countdownEnd; // ISO date — live countdown for promos
  final String? socialProofText;
  final String? termsUrl;
  final String? privacyUrl;
  final Map<String, PaywallPlanMeta> planMeta; // keyed by plan slug
  final Map<String, Map<String, dynamic>> localizations; // locale → text overrides
  final double heightFraction; // modal height as fraction of screen (0.5–1.0)

  PaywallConfig({
    required this.template,
    required this.title,
    this.subtitle,
    required this.features,
    required this.ctaText,
    required this.primaryColor,
    required this.theme,
    required this.planSlugs,
    this.highlightPlanSlug,
    this.badgeText,
    this.footerText,
    required this.showCloseButton,
    this.imageUrl,
    this.titleAlign = 'left',
    this.secondaryButtonText,
    this.backgroundColor,
    this.countdownEnd,
    this.socialProofText,
    this.termsUrl,
    this.privacyUrl,
    this.planMeta = const {},
    this.localizations = const {},
    this.heightFraction = 0.92,
  });

  factory PaywallConfig.fromJson(Map<String, dynamic> json) {
    return PaywallConfig(
      template: json['template'] as String? ?? 'sheet',
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String?,
      features: (json['features'] as List? ?? []).map((e) => e.toString()).toList(),
      ctaText: json['cta_text'] as String? ?? 'Continue',
      primaryColor: json['primary_color'] as String? ?? '#4F46E5',
      theme: json['theme'] as String? ?? 'dark',
      planSlugs: (json['plan_slugs'] as List? ?? []).map((e) => e.toString()).toList(),
      highlightPlanSlug: json['highlight_plan_slug'] as String?,
      badgeText: json['badge_text'] as String?,
      footerText: json['footer_text'] as String?,
      showCloseButton: json['show_close_button'] as bool? ?? true,
      imageUrl: json['image_url'] as String?,
      titleAlign: json['title_align'] as String? ?? 'left',
      secondaryButtonText: json['secondary_button_text'] as String?,
      backgroundColor: json['background_color'] as String?,
      countdownEnd: json['countdown_end'] as String?,
      socialProofText: json['social_proof_text'] as String?,
      termsUrl: json['terms_url'] as String?,
      privacyUrl: json['privacy_url'] as String?,
      planMeta: (json['plan_meta'] as Map<String, dynamic>? ?? {}).map(
        (k, v) => MapEntry(k, PaywallPlanMeta.fromJson(v as Map<String, dynamic>)),
      ),
      localizations: (json['localizations'] as Map<String, dynamic>? ?? {}).map(
        (k, v) => MapEntry(k, (v as Map<String, dynamic>)),
      ),
      heightFraction: (json['height_fraction'] as num?)?.toDouble() ?? 0.92,
    );
  }

  /// Apply text overrides for [locale] (e.g. "fr-FR" matches key "fr").
  PaywallConfig localize(String? locale) {
    if (locale == null || localizations.isEmpty) return this;
    final lower = locale.toLowerCase();
    final key = localizations.keys.cast<String?>().firstWhere(
          (k) => lower.startsWith(k!.toLowerCase()),
          orElse: () => null,
        );
    if (key == null) return this;
    final loc = localizations[key]!;
    return PaywallConfig(
      template: template,
      title: loc['title'] as String? ?? title,
      subtitle: loc['subtitle'] as String? ?? subtitle,
      features: (loc['features'] as List?)?.map((e) => e.toString()).toList() ?? features,
      ctaText: loc['cta_text'] as String? ?? ctaText,
      primaryColor: primaryColor,
      theme: theme,
      planSlugs: planSlugs,
      highlightPlanSlug: highlightPlanSlug,
      badgeText: loc['badge_text'] as String? ?? badgeText,
      footerText: loc['footer_text'] as String? ?? footerText,
      showCloseButton: showCloseButton,
      imageUrl: imageUrl,
      titleAlign: titleAlign,
      secondaryButtonText: loc['secondary_button_text'] as String? ?? secondaryButtonText,
      backgroundColor: backgroundColor,
      countdownEnd: countdownEnd,
      socialProofText: loc['social_proof_text'] as String? ?? socialProofText,
      termsUrl: termsUrl,
      privacyUrl: privacyUrl,
      planMeta: planMeta,
      localizations: localizations,
      heightFraction: heightFraction,
    );
  }
}

class PaywallPlanMeta {
  final String? badge;
  final String? note;
  final int? strikeAmount; // cents, shown struck through

  PaywallPlanMeta({this.badge, this.note, this.strikeAmount});

  factory PaywallPlanMeta.fromJson(Map<String, dynamic> json) {
    return PaywallPlanMeta(
      badge: json['badge'] as String?,
      note: json['note'] as String?,
      strikeAmount: json['strike_amount'] as int?,
    );
  }
}

/// A remotely configured paywall: layout + copy + the plans to display.
/// Fetched at runtime, so publishing from the dashboard updates the app
/// without a release.
class PaywallData {
  final String id;
  final String? name; // internal name set in the dashboard
  final bool published;
  final PaywallConfig config;
  final List<Plan> plans;

  PaywallData({
    required this.id,
    this.name,
    this.published = false,
    required this.config,
    required this.plans,
  });

  factory PaywallData.fromJson(Map<String, dynamic> json) {
    return PaywallData(
      id: json['id'] as String,
      name: json['name'] as String?,
      published: json['published'] as bool? ?? false,
      config: PaywallConfig.fromJson(json['config'] as Map<String, dynamic>),
      plans: (json['plans'] as List? ?? [])
          .map((p) => Plan.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Result of the server-side targeting engine: which paywall (if any)
/// to show this customer, and which rule decided it.
/// A win-back discount granted by the targeting rule that matched.
/// Pass [token] to [Paylo.subscribe] — the server verifies the signature
/// and applies the discount at checkout.
class PayloOffer {
  final int percentOff;
  final String duration; // once | forever | repeating
  final int? months; // when duration is "repeating"
  final String token;

  PayloOffer({required this.percentOff, required this.duration, this.months, required this.token});

  factory PayloOffer.fromJson(Map<String, dynamic> json) {
    return PayloOffer(
      percentOff: json['percent_off'] as int,
      duration: json['duration'] as String? ?? 'once',
      months: json['months'] as int?,
      token: json['token'] as String,
    );
  }
}

class ResolvedPaywall {
  final PaywallData? paywall;
  final String? ruleId;
  final String reason; // rule_matched, published_fallback, audience_no_match, frequency_capped, already_subscribed, no_match

  /// Discount from the matched rule — null when there is no offer.
  /// The paywall widget applies it automatically.
  final PayloOffer? offer;

  /// True when this result was served from the on-device cache because
  /// the network was unreachable (last successful resolve, kept 7 days).
  final bool fromCache;

  ResolvedPaywall({this.paywall, this.ruleId, required this.reason, this.offer, this.fromCache = false});

  bool get shouldShow => paywall != null;
}

class Plan {
  final String slug;
  final String name;
  final int amount;
  final String currency;
  final String interval;

  /// Free trial length in days — null when the plan has no trial.
  final int? trialDays;

  /// Price in cents after the active offer's discount — only set when the
  /// resolve response carried an offer. Display-only; Stripe recomputes.
  final int? discountedAmount;

  Plan({
    required this.slug,
    required this.name,
    required this.amount,
    required this.currency,
    required this.interval,
    this.trialDays,
    this.discountedAmount,
  });

  bool get hasTrial => (trialDays ?? 0) > 0;
  bool get hasDiscount => discountedAmount != null && discountedAmount! < amount;

  factory Plan.fromJson(Map<String, dynamic> json) {
    return Plan(
      slug: json['slug'] as String,
      name: json['name'] as String,
      amount: json['amount'] as int,
      currency: json['currency'] as String,
      interval: json['interval'] as String,
      trialDays: json['trial_days'] as int?,
      discountedAmount: json['discounted_amount'] as int?,
    );
  }
}

/// The outcome of a plan change — or a preview of one. Returned by
/// [Paylo.changePlan] and [Paylo.previewPlanChange].
class PlanChange {
  /// "upgrade", "downgrade" or "lateral".
  final String type;

  /// "immediate" (billed now) or "period_end" (takes effect at renewal).
  final String timing;

  final String fromPlan;
  final String toPlan;
  final String currency;

  /// Amount charged now, in cents — set on a preview of an immediate change.
  final int? prorationAmount;

  /// When a deferred (downgrade) change takes effect. Null for immediate ones.
  final DateTime? effectiveAt;

  PlanChange({
    required this.type,
    required this.timing,
    required this.fromPlan,
    required this.toPlan,
    required this.currency,
    this.prorationAmount,
    this.effectiveAt,
  });

  bool get isImmediate => timing == 'immediate';
  bool get isUpgrade => type == 'upgrade';

  factory PlanChange.fromJson(Map<String, dynamic> json) {
    return PlanChange(
      type: json['type'] as String? ?? 'upgrade',
      timing: json['timing'] as String? ?? 'immediate',
      fromPlan: json['from_plan']?.toString() ?? '',
      toPlan: json['to_plan']?.toString() ?? '',
      currency: json['currency'] as String? ?? 'eur',
      prorationAmount: json['proration_amount'] as int?,
      effectiveAt: json['effective_at'] != null
          ? DateTime.parse(json['effective_at'].toString())
          : null,
    );
  }
}

/// A downgrade the customer already scheduled — surfaced on [CustomerStatus]
/// so apps can show "Switches to <plan> on <date>".
class ScheduledChange {
  final String planId;
  final String? planName;
  final String? planSlug;
  final DateTime? effectiveAt;

  ScheduledChange({
    required this.planId,
    this.planName,
    this.planSlug,
    this.effectiveAt,
  });

  factory ScheduledChange.fromJson(Map<String, dynamic> json) {
    return ScheduledChange(
      planId: json['plan_id'] as String,
      planName: json['plan_name']?.toString(),
      planSlug: json['plan_slug']?.toString(),
      effectiveAt: json['effective_at'] != null
          ? DateTime.parse(json['effective_at'].toString())
          : null,
    );
  }
}

/// Main Paylo SDK client.
///
/// The ultra-short path — one line of setup, everything else is automatic
/// (anonymous customer id, plans, environment):
///
/// ```dart
/// await Paylo.configure('pk_test_...');           // in main()
/// // Paylo.identify(user.id);                     // at login (optional)
///
/// await PayloPaywall.showIfNeeded(context, placement: 'onboarding');
/// if (await Paylo.hasEntitlement('pro')) { /* unlock */ }
/// ```
///
/// The explicit instance API remains available:
///
/// ```dart
/// final paylo = Paylo('pk_test_...');
/// final status = await paylo.customerStatus(user.id);
/// ```
class Paylo {
  final PayloConfig _config;
  final http.Client _client;

  // Filled by [_bootstrap] — lets every call work without a developerId.
  String? _developerId;
  List<Plan> _bootstrapPlans = const [];
  bool _hasPublishedPaywall = false;

  // Current customer identity (anonymous until [identify] is called).
  String? _customerId;

  Paylo(String apiKey, {String? baseUrl})
      : _config = PayloConfig(
          apiKey: apiKey,
          baseUrl: baseUrl ?? kPayloDefaultBaseUrl,
        ),
        _client = http.Client();

  // ── Shared instance (the ultra-simple path) ──

  static Paylo? _shared;
  static const _customerIdPrefsKey = 'paylo_customer_id';

  /// The instance created by [configure]. Widgets and statics use it so
  /// nothing needs to be passed around.
  static Paylo get instance {
    final shared = _shared;
    if (shared == null) {
      throw PayloException('Call await Paylo.configure(apiKey) before using Paylo');
    }
    return shared;
  }

  static bool get isConfigured => _shared != null;

  /// One-line setup. Creates the shared instance, restores (or creates)
  /// a persistent anonymous customer id, and preloads your plans and
  /// paywall from the server. Never throws for network reasons — the
  /// bootstrap retries lazily on first use.
  static Future<Paylo> configure(String apiKey, {String? baseUrl, String? customerId}) async {
    final paylo = Paylo(apiKey, baseUrl: baseUrl);
    paylo._customerId = customerId ?? await _loadOrCreateCustomerId();
    try {
      await paylo._bootstrap();
    } catch (_) {
      // Offline start — resolved on the next call via _requireDeveloperId.
    }
    _shared = paylo;
    return paylo;
  }

  /// Attach the anonymous history to your real user id at login. The
  /// server merges purchases, entitlements and paywall history so
  /// nothing is lost. Safe to call on every app start.
  static Future<void> identify(String userId) => instance._identify(userId);

  /// Back to a fresh anonymous identity (call at logout).
  static Future<void> logOut() => instance._logOut();

  /// The current customer id (anonymous `anon_…` or the identified one).
  static String get customerId {
    final id = instance._customerId;
    if (id == null) throw PayloException('No customer id — was configure() awaited?');
    return id;
  }

  /// Plans preloaded at [configure] time (empty if the app started
  /// offline — they load with the paywall anyway).
  static List<Plan> get plans => instance._bootstrapPlans;

  /// The current customer's status — subscription, trial, entitlements.
  static Future<CustomerStatus> status() => instance.customerStatus(customerId);

  /// `if (await Paylo.hasEntitlement('pro')) { … }`
  static Future<bool> hasEntitlement(String key) async => (await status()).hasEntitlement(key);

  /// True when the customer has access (active sub, trial, or lifetime).
  static Future<bool> isSubscribed() async => (await status()).hasActiveSubscription;

  /// Open the Stripe customer portal for the current customer's active
  /// subscription — cancel, change card, invoices. Returns false when
  /// there is nothing to manage (no sub, or a one-time purchase).
  static Future<bool> openManagement({String? returnUrl}) async {
    final s = await status();
    final sub = s.activeSubscription;
    if (sub == null || !s.canManage) return false;
    await instance.openPortal(sub.id, returnUrl: returnUrl);
    return true;
  }

  /// Move the current customer's active subscription to another plan.
  /// Returns null when there is no active subscription to change.
  /// (PayloAccountView does this for you — this is for custom UIs.)
  static Future<PlanChange?> switchPlan(String newPlanId) async {
    final sub = (await status()).activeSubscription;
    if (sub == null) return null;
    return instance.changePlan(sub.id, newPlanId);
  }

  /// Preview [switchPlan] for the current customer's active subscription.
  static Future<PlanChange?> previewSwitchPlan(String newPlanId) async {
    final sub = (await status()).activeSubscription;
    if (sub == null) return null;
    return instance.previewPlanChange(sub.id, newPlanId);
  }

  static Future<String> _loadOrCreateCustomerId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(_customerIdPrefsKey);
      if (existing != null && existing.isNotEmpty) return existing;
      final id = _newAnonymousId();
      await prefs.setString(_customerIdPrefsKey, id);
      return id;
    } catch (_) {
      return _newAnonymousId(); // storage unavailable — stable for this run only
    }
  }

  static String _newAnonymousId() {
    final rand = Random.secure();
    final hex = List.generate(16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'anon_$hex';
  }

  Future<void> _persistCustomerId(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_customerIdPrefsKey, id);
    } catch (_) {}
  }

  Future<void> _identify(String userId) async {
    final previous = _customerId;
    if (previous == userId) return;
    if (previous != null) {
      try {
        await _request('POST', '/v1/customers/identify', body: {
          'previous_customer_id': previous,
          'customer_id': userId,
        });
      } catch (_) {
        // Merge is best-effort — the identity switch still happens.
      }
    }
    _customerId = userId;
    await _persistCustomerId(userId);
  }

  Future<void> _logOut() async {
    final id = _newAnonymousId();
    _customerId = id;
    await _persistCustomerId(id);
  }

  // ── Bootstrap — the pk_ key alone identifies the account ──

  Future<void> _bootstrap() async {
    final json = await _request('GET', '/v1/sdk/bootstrap');
    _developerId = json['developer_id'] as String;
    _bootstrapPlans = (json['plans'] as List? ?? [])
        .map((p) => Plan.fromJson(p as Map<String, dynamic>))
        .toList();
    _hasPublishedPaywall = json['has_published_paywall'] == true;
  }

  /// The account id behind this API key — fetched once, cached. Used by
  /// the paywall widgets so you never pass a developerId again.
  Future<String> requireDeveloperId() async {
    if (_developerId != null) return _developerId!;
    await _bootstrap();
    return _developerId!;
  }

  /// Whether a paywall was published (known after bootstrap).
  bool get hasPublishedPaywall => _hasPublishedPaywall;

  /// This instance's customer id, when it was set up via [configure].
  String? get currentCustomerId => _customerId;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_config.apiKey}',
        'Content-Type': 'application/json',
      };

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('${_config.baseUrl}$path');
    late http.Response res;

    switch (method) {
      case 'GET':
        res = await _client.get(uri, headers: _headers);
        break;
      case 'POST':
        res = await _client.post(uri, headers: _headers, body: jsonEncode(body));
        break;
      default:
        throw PayloException('Unsupported method: $method');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;

    if (res.statusCode >= 400) {
      throw PayloException(
        json['error'] as String? ?? 'Request failed',
        statusCode: res.statusCode,
      );
    }

    return json;
  }

  // ── One-time payments ──

  /// Create a one-time payment session and open checkout in browser.
  Future<CheckoutResult> checkout({
    required String productName,
    required int amount,
    String currency = 'eur',
    String? description,
    String? successUrl,
    String? cancelUrl,
    bool openBrowser = true,
  }) async {
    final json = await _request('POST', '/v1/sessions', body: {
      'product_name': productName,
      'amount': amount,
      'currency': currency,
      if (description != null) 'description': description,
      if (successUrl != null) 'success_url': successUrl,
      if (cancelUrl != null) 'cancel_url': cancelUrl,
    });

    final result = CheckoutResult.fromJson(json);

    if (openBrowser) {
      await launchUrl(Uri.parse(result.url), mode: LaunchMode.externalApplication);
    }

    return result;
  }

  /// Check the status of a payment session.
  Future<SessionStatus> getSession(String sessionId) async {
    final json = await _request('GET', '/v1/sessions/$sessionId');
    return SessionStatus.fromJson(json);
  }

  /// Poll until a session completes or expires.
  Future<SessionStatus> waitForPayment(
    String sessionId, {
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final status = await getSession(sessionId);
      if (status.status != 'pending') return status;
      await Future.delayed(interval);
    }

    throw PayloException('Payment check timed out');
  }

  // ── Subscriptions ──

  /// Create a subscription checkout and open in browser.
  ///
  /// [offerToken] applies a discount granted by a targeting rule — pass
  /// `resolved.offer?.token`. The paywall widget does this automatically.
  Future<SubscriptionResult> subscribe({
    required String planId,
    required String customerId,
    String? customerEmail,
    String? successUrl,
    String? cancelUrl,
    String? offerToken,
    bool openBrowser = true,
  }) async {
    final json = await _request('POST', '/v1/subscriptions', body: {
      'plan_id': planId,
      'customer_id': customerId,
      if (customerEmail != null) 'customer_email': customerEmail,
      if (successUrl != null) 'success_url': successUrl,
      if (cancelUrl != null) 'cancel_url': cancelUrl,
      if (offerToken != null) 'offer_token': offerToken,
    });

    final result = SubscriptionResult.fromJson(json);

    if (openBrowser) {
      await launchUrl(Uri.parse(result.url), mode: LaunchMode.externalApplication);
    }

    return result;
  }

  /// Get subscription details.
  Future<SubscriptionStatus> getSubscription(String subscriptionId) async {
    final json = await _request('GET', '/v1/subscriptions/$subscriptionId');
    return SubscriptionStatus.fromJson(json);
  }

  /// Check if a customer has an active subscription.
  Future<CustomerStatus> customerStatus(String customerId) async {
    final json = await _request('GET', '/v1/customers/$customerId/status');
    return CustomerStatus.fromJson(json);
  }

  /// Open the Stripe customer portal for a subscription — the customer
  /// can cancel, or update their payment method there.
  ///
  /// ```dart
  /// final status = await paylo.customerStatus(user.id);
  /// final sub = status.activeSubscription;
  /// if (sub != null) {
  ///   await paylo.openPortal(sub.id, returnUrl: 'https://yourapp.com/account');
  /// }
  /// ```
  Future<String> openPortal(
    String subscriptionId, {
    String? returnUrl,
    bool openBrowser = true,
  }) async {
    final json = await _request('POST', '/v1/subscriptions/$subscriptionId/portal', body: {
      if (returnUrl != null) 'return_url': returnUrl,
    });
    final url = json['url'] as String;
    if (openBrowser) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
    return url;
  }

  // ── Change plan (upgrade / downgrade) ──

  /// Preview a plan change without applying it. Returns the proration amount
  /// (for an immediate upgrade) or the effective date (for a downgrade), so
  /// you can confirm with the customer before charging anything.
  Future<PlanChange> previewPlanChange(String subscriptionId, String newPlanId) async {
    final json = await _request('POST', '/v1/subscriptions/$subscriptionId/change-plan', body: {
      'new_plan_id': newPlanId,
      'preview': true,
    });
    return PlanChange.fromJson(json['change'] as Map<String, dynamic>);
  }

  /// Move a subscription to another plan. The server decides everything: an
  /// upgrade bills the proration immediately, a downgrade takes effect at the
  /// end of the current period. You just pass the target plan (slug or id).
  Future<PlanChange> changePlan(String subscriptionId, String newPlanId) async {
    final json = await _request('POST', '/v1/subscriptions/$subscriptionId/change-plan', body: {
      'new_plan_id': newPlanId,
    });
    return PlanChange.fromJson(json['change'] as Map<String, dynamic>);
  }

  // ── Plans ──

  /// Fetch available plans.
  ///
  /// Public endpoint — the API key isn't required, but the SDK sends it so
  /// the server returns this key's environment (test vs live) regardless of
  /// the dashboard mode toggle.
  Future<List<Plan>> getPlans(String developerId) async {
    final uri = Uri.parse('${_config.baseUrl}/v1/public/$developerId/plans');
    final res = await _client.get(uri, headers: _headers);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final plans = json['plans'] as List;
    return plans.map((p) => Plan.fromJson(p as Map<String, dynamic>)).toList();
  }

  /// Fetch the published paywall.
  ///
  /// Returns null if no paywall is published. The paywall is configured
  /// remotely from the Paylo dashboard — republish there and the app shows
  /// the new version on next fetch, no app update needed. Plans are served
  /// for this API key's environment (test vs live).
  Future<PaywallData?> getPaywall(String developerId) async {
    final uri = Uri.parse('${_config.baseUrl}/v1/public/$developerId/paywall');
    final res = await _client.get(uri, headers: _headers);
    if (res.statusCode == 404) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw PayloException(json['error'] as String? ?? 'Request failed', statusCode: res.statusCode);
    }
    return PaywallData.fromJson(json);
  }

  /// Fetch all paywalls — published or not.
  ///
  /// Use this to pick which paywall to show per user (A/B tests,
  /// segments, promos…). Match by [PaywallData.name] or id.
  Future<List<PaywallData>> getPaywalls(String developerId) async {
    final uri = Uri.parse('${_config.baseUrl}/v1/public/$developerId/paywalls');
    final res = await _client.get(uri, headers: _headers);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw PayloException(json['error'] as String? ?? 'Request failed', statusCode: res.statusCode);
    }
    return (json['paywalls'] as List? ?? [])
        .map((p) => PaywallData.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  // App version for min_app_version targeting rules — read once from the
  // platform, never fails the resolve.
  static String? _cachedAppVersion;
  static Future<String?> _detectAppVersion() async {
    if (_cachedAppVersion != null) return _cachedAppVersion;
    try {
      _cachedAppVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    return _cachedAppVersion;
  }

  /// Ask the server which paywall to show this customer.
  ///
  /// All targeting logic — audience, placements, A/B tests, schedules,
  /// frequency caps — is configured in the Paylo dashboard and evaluated
  /// server-side. The app just sends its context; subscriptions and plans
  /// are matched in this API key's environment (test vs live).
  ///
  /// [appVersion] defaults to the app's own version (from the platform
  /// package info), so min-app-version rules work without any wiring.
  Future<ResolvedPaywall> resolvePaywall({
    required String developerId,
    required String customerId,
    String? placement,
    String? platform, // "ios" | "android" | "web"
    String? locale,
    String? appVersion,
    Map<String, dynamic>? attributes,
  }) async {
    appVersion ??= await _detectAppVersion();
    final uri = Uri.parse('${_config.baseUrl}/v1/public/$developerId/paywall/resolve');
    final cacheKey = 'paylo_resolve_${developerId}_${customerId}_${placement ?? ''}';

    late http.Response res;
    try {
      res = await _client.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'customer_id': customerId,
          if (placement != null) 'placement': placement,
          if (platform != null) 'platform': platform,
          if (locale != null) 'locale': locale,
          if (appVersion != null) 'app_version': appVersion,
          if (attributes != null) 'attributes': attributes,
        }),
      );
    } catch (_) {
      // Network unreachable — fall back to the last successful resolve
      // so the paywall still shows offline. Server errors (4xx/5xx) are
      // real answers and never hit this path.
      final cached = await _readCache(cacheKey);
      if (cached != null) return _parseResolved(cached, fromCache: true);
      rethrow;
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw PayloException(json['error'] as String? ?? 'Request failed', statusCode: res.statusCode);
    }
    await _writeCache(cacheKey, res.body);
    return _parseResolved(json);
  }

  static ResolvedPaywall _parseResolved(Map<String, dynamic> json, {bool fromCache = false}) {
    return ResolvedPaywall(
      paywall: json['paywall'] != null
          ? PaywallData.fromJson(json['paywall'] as Map<String, dynamic>)
          : null,
      ruleId: json['rule_id'] as String?,
      reason: json['reason'] as String? ?? 'no_match',
      offer: json['offer'] != null
          ? PayloOffer.fromJson(json['offer'] as Map<String, dynamic>)
          : null,
      fromCache: fromCache,
    );
  }

  // ── Offline cache — last successful resolve, served only when the
  // network is unreachable, kept at most 7 days. Never throws. ──

  static const Duration _cacheTtl = Duration(days: 7);

  static Future<void> _writeCache(String key, String body) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode({'at': DateTime.now().millisecondsSinceEpoch, 'body': body}),
      );
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> _readCache(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final entry = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(entry['at'] as int? ?? 0);
      if (DateTime.now().difference(at) > _cacheTtl) return null;
      return jsonDecode(entry['body'] as String) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Report a paywall event. The PayloPaywall widget calls this
  /// automatically — impressions feed frequency caps and the dashboard
  /// analytics.
  Future<void> logPaywallEvent(
    String developerId, {
    required String paywallId,
    required String customerId,
    required String type, // impression, dismiss, checkout_opened
    String? ruleId,
    String? placement,
  }) async {
    final uri = Uri.parse('${_config.baseUrl}/v1/public/$developerId/paywall-events');
    try {
      await _client.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'paywall_id': paywallId,
          'customer_id': customerId,
          'type': type,
          if (ruleId != null) 'rule_id': ruleId,
          if (placement != null) 'placement': placement,
        }),
      );
    } catch (_) {
      // Tracking must never break the app.
    }
  }

  /// Dispose the HTTP client.
  void dispose() {
    _client.close();
  }
}
