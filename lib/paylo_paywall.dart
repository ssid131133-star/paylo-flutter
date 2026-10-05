library paylo_paywall;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'paylo.dart';

Color _hexColor(String hex) {
  final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x4F46E5;
  return Color(0xFF000000 | value);
}

String _formatAmount(int cents, String currency) {
  const symbols = {'eur': '€', 'usd': '\$', 'gbp': '£'};
  final symbol = symbols[currency] ?? currency.toUpperCase();
  var price = (cents / 100).toStringAsFixed(2);
  if (price.endsWith('.00')) price = price.substring(0, price.length - 3);
  return '$symbol$price';
}

String _intervalSuffix(String interval) {
  const intervals = {
    'daily': '/day',
    'weekly': '/wk',
    'monthly': '/mo',
    'yearly': '/yr',
    'one_time': '',
  };
  return intervals[interval] ?? '';
}

String _formatPrice(Plan plan) {
  return '${_formatAmount(plan.amount, plan.currency)}${_intervalSuffix(plan.interval)}';
}

/// Native paywall rendered from a remotely configured [PaywallData].
///
/// The one-liner — targeting, A/B tests, schedules and frequency caps are
/// all configured in the Paylo dashboard and evaluated server-side:
///
/// ```dart
/// await PayloPaywall.showIfNeeded(context,
///   paylo: paylo, developerId: devId, customerId: user.id,
///   placement: 'onboarding');
/// ```
class PayloPaywall extends StatefulWidget {
  final Paylo paylo;
  final PaywallData paywall;
  final String customerId;
  final String? customerEmail;

  /// When set, impressions/dismissals/checkouts are reported automatically
  /// (feeds dashboard analytics and frequency caps).
  final String? developerId;
  final String? ruleId;
  final String? placement;

  /// Locale for text overrides configured in the dashboard (e.g. "fr").
  final String? locale;

  /// Pre-select a plan (by slug) instead of the dashboard highlight —
  /// e.g. when the user tapped "Pro" in your own pricing UI.
  final String? preselectedPlanSlug;

  /// Win-back discount from the matched rule — prices render struck
  /// through and the checkout applies it (token sent to subscribe).
  final PayloOffer? offer;

  /// Modal (bottom sheet) or embedded in a page. Set by [show]/[inline].
  final bool modal;

  /// Inline mode: called when the user taps the close/secondary button.
  final VoidCallback? onDismiss;

  /// Inline mode: called after the checkout opened in the browser.
  final void Function(SubscriptionResult result)? onCheckoutOpened;

  const PayloPaywall({
    super.key,
    required this.paylo,
    required this.paywall,
    required this.customerId,
    this.customerEmail,
    this.developerId,
    this.ruleId,
    this.placement,
    this.locale,
    this.preselectedPlanSlug,
    this.offer,
    this.modal = false,
    this.onDismiss,
    this.onCheckoutOpened,
  });

  /// Present the paywall as a modal sheet. Resolves with the
  /// [SubscriptionResult] if the user tapped the CTA (checkout opened),
  /// or null if they dismissed it.
  ///
  /// [paywall] may be null (e.g. straight from `resolvePaywall(...).paywall`)
  /// — nothing is shown and null is returned.
  static Future<SubscriptionResult?> show(
    BuildContext context, {
    Paylo? paylo,
    required PaywallData? paywall,
    String? customerId,
    String? customerEmail,
    String? developerId,
    String? ruleId,
    String? placement,
    String? locale,
    String? preselectedPlanSlug,
    PayloOffer? offer,
  }) {
    if (paywall == null) return Future.value(null);
    final client = paylo ?? Paylo.instance;
    final cid = customerId ??
        client.currentCustomerId ??
        (throw PayloException('customerId is required when Paylo.configure() was not used'));
    final heightFraction = paywall.config.heightFraction.clamp(0.5, 1.0);
    // The bottom sheet sits below the status bar, so its maximum height is
    // screenHeight - viewPadding.top.  We apply the fraction to that value so
    // that 1.0 truly fills everything below the status bar.
    final mq = MediaQuery.of(context);
    final maxHeight = mq.size.height - mq.viewPadding.top;
    final sheetHeight = maxHeight * heightFraction;
    return showModalBottomSheet<SubscriptionResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: sheetHeight,
        child: PayloPaywall(
          paylo: client,
          paywall: paywall,
          customerId: cid,
          customerEmail: customerEmail,
          developerId: developerId,
          ruleId: ruleId,
          placement: placement,
          locale: locale,
          preselectedPlanSlug: preselectedPlanSlug,
          offer: offer,
          modal: true,
        ),
      ),
    );
  }

  /// Embed the paywall in a page (e.g. a "Subscription" screen) instead
  /// of a modal. Resolves the right paywall itself and handles its own
  /// loading state — drop it straight into a Scaffold body:
  ///
  /// ```dart
  /// PayloPaywall.inline(
  ///   paylo: paylo, developerId: devId, customerId: user.id,
  ///   placement: 'subscription_page',
  /// )
  /// ```
  ///
  /// Renders nothing when the server says nothing should be shown
  /// (already subscribed, frequency capped…) — override with [emptyBuilder].
  static Widget inline({
    Key? key,
    Paylo? paylo,
    String? developerId,
    String? customerId,
    String? customerEmail,
    String? placement,
    String? locale,
    String? appVersion,
    Map<String, dynamic>? attributes,
    String? preselectedPlanSlug,
    void Function(SubscriptionResult result)? onCheckoutOpened,
    WidgetBuilder? loadingBuilder,
    WidgetBuilder? emptyBuilder,
  }) {
    final client = paylo ?? Paylo.instance;
    return _InlinePaywall(
      key: key,
      paylo: client,
      developerId: developerId,
      customerId: customerId ??
          client.currentCustomerId ??
          (throw PayloException('customerId is required when Paylo.configure() was not used')),
      customerEmail: customerEmail,
      placement: placement,
      locale: locale,
      appVersion: appVersion,
      attributes: attributes,
      preselectedPlanSlug: preselectedPlanSlug,
      onCheckoutOpened: onCheckoutOpened,
      loadingBuilder: loadingBuilder,
      emptyBuilder: emptyBuilder,
    );
  }

  /// The one-liner. Asks the server which paywall this customer should
  /// see (dashboard rules: audience, placement, A/B, schedule, frequency)
  /// and shows it. Returns null when nothing should be shown.
  static Future<SubscriptionResult?> showIfNeeded(
    BuildContext context, {
    Paylo? paylo,
    String? developerId,
    String? customerId,
    String? customerEmail,
    String? placement,
    String? locale,
    String? appVersion,
    Map<String, dynamic>? attributes,
    String? preselectedPlanSlug,
  }) async {
    // Everything defaults to the shared instance set up by
    // Paylo.configure() — the whole call collapses to
    // showIfNeeded(context, placement: '…').
    final client = paylo ?? Paylo.instance;
    final devId = developerId ?? await client.requireDeveloperId();
    final cid = customerId ??
        client.currentCustomerId ??
        (throw PayloException('customerId is required when Paylo.configure() was not used'));
    if (!context.mounted) return null;
    final platform = switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 'ios',
      TargetPlatform.android => 'android',
      _ => 'web',
    };
    final deviceLocale = locale ?? Localizations.maybeLocaleOf(context)?.toLanguageTag();

    final resolved = await client.resolvePaywall(
      developerId: devId,
      customerId: cid,
      placement: placement,
      platform: platform,
      locale: deviceLocale,
      appVersion: appVersion,
      attributes: attributes,
    );
    if (!resolved.shouldShow) {
      // Silent nothing is impossible to debug — say why in debug builds
      // (published_fallback, audience_no_match, frequency_capped,
      // already_subscribed, no_match).
      assert(() {
        debugPrint('[Paylo] showIfNeeded: no paywall (reason: ${resolved.reason})');
        return true;
      }());
      return null;
    }

    if (!context.mounted) return null;
    return show(
      context,
      paylo: client,
      paywall: resolved.paywall,
      customerId: cid,
      customerEmail: customerEmail,
      developerId: devId,
      ruleId: resolved.ruleId,
      placement: placement,
      locale: deviceLocale,
      preselectedPlanSlug: preselectedPlanSlug,
      offer: resolved.offer,
    );
  }

  @override
  State<PayloPaywall> createState() => _PayloPaywallState();
}

class _PayloPaywallState extends State<PayloPaywall> {
  String? _selectedSlug;
  bool _loading = false;
  bool _checkoutOpened = false;
  Timer? _countdownTimer;
  Duration? _remaining;

  late final PaywallConfig _config = widget.paywall.config.localize(widget.locale);
  List<Plan> get _plans => widget.paywall.plans;

  @override
  void initState() {
    super.initState();
    _selectedSlug = widget.preselectedPlanSlug ??
        _config.highlightPlanSlug ??
        (_plans.isNotEmpty ? _plans.first.slug : null);
    _track('impression');
    _startCountdown();
  }

  void _dismiss() {
    if (widget.modal) {
      Navigator.of(context).pop();
    } else {
      widget.onDismiss?.call();
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    if (!_checkoutOpened) _track('dismiss');
    super.dispose();
  }

  void _track(String type) {
    final devId = widget.developerId;
    if (devId == null) return;
    widget.paylo.logPaywallEvent(
      devId,
      paywallId: widget.paywall.id,
      customerId: widget.customerId,
      type: type,
      ruleId: widget.ruleId,
      placement: widget.placement,
    );
  }

  void _startCountdown() {
    final end = _config.countdownEnd;
    if (end == null) return;
    final target = DateTime.tryParse(end);
    if (target == null) return;

    void tick() {
      final left = target.difference(DateTime.now());
      if (!mounted) return;
      setState(() => _remaining = left.isNegative ? null : left);
      if (left.isNegative) _countdownTimer?.cancel();
    }

    tick();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<void> _subscribe() async {
    final slug = _selectedSlug;
    if (slug == null || _loading) return;
    setState(() => _loading = true);
    try {
      final result = await widget.paylo.subscribe(
        planId: slug,
        customerId: widget.customerId,
        customerEmail: widget.customerEmail,
        offerToken: widget.offer?.token,
      );
      _checkoutOpened = true;
      _track('checkout_opened');
      if (!mounted) return;
      if (widget.modal) {
        Navigator.of(context).pop(result);
      } else {
        setState(() => _loading = false);
        widget.onCheckoutOpened?.call(result);
      }
    } on PayloException {
      if (mounted) setState(() => _loading = false);
      rethrow;
    }
  }

  String get _countdownLabel {
    final r = _remaining!;
    if (r.inHours >= 48) return '${r.inDays} days';
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(r.inHours)}:${pad(r.inMinutes % 60)}:${pad(r.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final dark = _config.theme != 'light';
    final accent = _hexColor(_config.primaryColor);
    final bg = _config.backgroundColor != null
        ? _hexColor(_config.backgroundColor!)
        : dark
            ? const Color(0xFF0C0C0C)
            : Colors.white;
    final centered = _config.titleAlign == 'center';
    final text = dark ? Colors.white : const Color(0xFF111827);
    final subText = dark ? Colors.white54 : const Color(0xFF6B7280);
    final cardBg = dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF9FAFB);
    final cardBorder = dark ? Colors.white12 : const Color(0xFFE5E7EB);

    return Container(
      height: widget.modal ? double.infinity : null,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: widget.modal
            ? const BorderRadius.vertical(top: Radius.circular(28))
            : BorderRadius.circular(20),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: widget.modal ? 16 : 24,
        bottom: widget.modal ? MediaQuery.of(context).viewPadding.bottom + 24 : 24,
      ),
      child: SingleChildScrollView(
        physics: widget.modal ? null : const NeverScrollableScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          if (_config.showCloseButton && (widget.modal || widget.onDismiss != null))
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: _dismiss,
                child: Container(
                  height: 30,
                  width: 30,
                  decoration: BoxDecoration(color: cardBg, shape: BoxShape.circle),
                  child: Icon(Icons.close, size: 16, color: subText),
                ),
              ),
            ),
          if (_config.imageUrl != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                _config.imageUrl!,
                height: 120,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: double.infinity,
            child: Text(
              _config.title,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: text, height: 1.2),
            ),
          ),
          if (_config.subtitle != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: Text(
                _config.subtitle!,
                textAlign: centered ? TextAlign.center : TextAlign.start,
                style: TextStyle(fontSize: 14, color: subText, height: 1.4),
              ),
            ),
          ],
          if (_config.socialProofText != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: Text(
                _config.socialProofText!,
                textAlign: centered ? TextAlign.center : TextAlign.start,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: subText),
              ),
            ),
          ],
          if (_remaining != null) ...[
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(999)),
                child: Text(
                  'Offer ends in $_countdownLabel',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
          if (_config.features.isNotEmpty) ...[
            const SizedBox(height: 18),
            ..._config.features.map(
              (f) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      height: 20,
                      width: 20,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.check, size: 12, color: accent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(f, style: TextStyle(fontSize: 14, color: text))),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          ..._plans.map((plan) {
            final selected = plan.slug == _selectedSlug;
            final meta = _config.planMeta[plan.slug];
            final badge = meta?.badge ?? (selected ? _config.badgeText : null);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => setState(() => _selectedSlug = plan.slug),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected ? accent : cardBorder,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            height: 18,
                            width: 18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected ? accent : cardBorder,
                                width: 2,
                              ),
                            ),
                            child: selected
                                ? Center(
                                    child: Container(
                                      height: 8,
                                      width: 8,
                                      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                                    ),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  plan.name,
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: text),
                                ),
                                if (plan.hasTrial)
                                  Text(
                                    '${plan.trialDays}-day free trial',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: accent),
                                  ),
                                if (meta?.note != null)
                                  Text(
                                    meta!.note!,
                                    style: TextStyle(fontSize: 11, color: subText),
                                  ),
                              ],
                            ),
                          ),
                          if (plan.hasDiscount) ...[
                            Text(
                              _formatAmount(plan.amount, plan.currency),
                              style: TextStyle(
                                fontSize: 12,
                                color: subText,
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _formatAmount(plan.discountedAmount!, plan.currency) + _intervalSuffix(plan.interval),
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: accent),
                            ),
                          ] else ...[
                            if (meta?.strikeAmount != null && meta!.strikeAmount! > plan.amount) ...[
                              Text(
                                _formatAmount(meta.strikeAmount!, plan.currency),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: subText,
                                  decoration: TextDecoration.lineThrough,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Text(
                              _formatPrice(plan),
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: text),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (badge != null)
                      Positioned(
                        top: -8,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            badge.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loading ? null : _subscribe,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      _config.ctaText,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
            ),
          ),
          Builder(builder: (context) {
            final selected = widget.paywall.plans
                .cast<Plan?>()
                .firstWhere((p) => p!.slug == _selectedSlug, orElse: () => null);
            if (selected == null || !selected.hasTrial) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Center(
                child: Text(
                  '${selected.trialDays} days free, then ${_formatPrice(selected)} — cancel anytime',
                  style: TextStyle(fontSize: 11, color: subText),
                ),
              ),
            );
          }),
          if (_config.secondaryButtonText != null && (widget.modal || widget.onDismiss != null)) ...[
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _dismiss,
                child: Text(
                  _config.secondaryButtonText!,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: subText),
                ),
              ),
            ),
          ],
          if (_config.footerText != null) ...[
            const SizedBox(height: 10),
            Center(
              child: Text(
                _config.footerText!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: subText),
              ),
            ),
          ],
          if (_config.termsUrl != null || _config.privacyUrl != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_config.termsUrl != null)
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse(_config.termsUrl!), mode: LaunchMode.externalApplication),
                    child: Text('Terms', style: TextStyle(fontSize: 10, color: subText, decoration: TextDecoration.underline)),
                  ),
                if (_config.termsUrl != null && _config.privacyUrl != null)
                  Text(' · ', style: TextStyle(fontSize: 10, color: subText)),
                if (_config.privacyUrl != null)
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse(_config.privacyUrl!), mode: LaunchMode.externalApplication),
                    child: Text('Privacy', style: TextStyle(fontSize: 10, color: subText, decoration: TextDecoration.underline)),
                  ),
              ],
            ),
          ],
        ],
        ),
      ),
    );
  }
}

/// Self-loading paywall for embedding in a page (see [PayloPaywall.inline]).
class _InlinePaywall extends StatefulWidget {
  final Paylo paylo;
  final String? developerId; // null = resolved from the SDK bootstrap
  final String customerId;
  final String? customerEmail;
  final String? placement;
  final String? locale;
  final String? appVersion;
  final Map<String, dynamic>? attributes;
  final String? preselectedPlanSlug;
  final void Function(SubscriptionResult result)? onCheckoutOpened;
  final WidgetBuilder? loadingBuilder;
  final WidgetBuilder? emptyBuilder;

  const _InlinePaywall({
    super.key,
    required this.paylo,
    this.developerId,
    required this.customerId,
    this.customerEmail,
    this.placement,
    this.locale,
    this.appVersion,
    this.attributes,
    this.preselectedPlanSlug,
    this.onCheckoutOpened,
    this.loadingBuilder,
    this.emptyBuilder,
  });

  @override
  State<_InlinePaywall> createState() => _InlinePaywallState();
}

class _InlinePaywallState extends State<_InlinePaywall> {
  Future<ResolvedPaywall>? _future;
  String? _resolvedLocale;
  String? _developerId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve once — platform and locale need a BuildContext.
    if (_future != null) return;
    final platform = switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 'ios',
      TargetPlatform.android => 'android',
      _ => 'web',
    };
    _resolvedLocale = widget.locale ?? Localizations.maybeLocaleOf(context)?.toLanguageTag();
    _future = () async {
      _developerId = widget.developerId ?? await widget.paylo.requireDeveloperId();
      return widget.paylo.resolvePaywall(
        developerId: _developerId!,
        customerId: widget.customerId,
        placement: widget.placement,
        platform: platform,
        locale: _resolvedLocale,
        appVersion: widget.appVersion,
        attributes: widget.attributes,
      );
    }();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ResolvedPaywall>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loadingBuilder?.call(context) ??
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
        }
        final paywall = snapshot.data?.paywall;
        if (snapshot.hasError || paywall == null) {
          return widget.emptyBuilder?.call(context) ?? const SizedBox.shrink();
        }
        return PayloPaywall(
          paylo: widget.paylo,
          paywall: paywall,
          customerId: widget.customerId,
          customerEmail: widget.customerEmail,
          developerId: _developerId,
          ruleId: snapshot.data?.ruleId,
          placement: widget.placement,
          locale: _resolvedLocale,
          preselectedPlanSlug: widget.preselectedPlanSlug,
          offer: snapshot.data?.offer,
          onCheckoutOpened: widget.onCheckoutOpened,
        );
      },
    );
  }
}

/// The whole "my subscription" page in one widget.
///
/// ```dart
/// Scaffold(body: PayloAccountView())
/// ```
///
/// Renders the right thing by itself:
/// - active/trialing subscription → current plan, price, renewal (or
///   trial end) date, and a "Manage subscription" button opening the
///   Stripe customer portal (cancel, change card, invoices);
/// - one-time (lifetime) purchase → the plan, no manage button (there
///   is nothing to manage);
/// - no subscription → the paywall, resolved with your targeting rules.
///
/// Requires `Paylo.configure()` (or pass [paylo] + [customerId]).
class PayloAccountView extends StatefulWidget {
  final Paylo? paylo;
  final String? customerId;

  /// Placement sent to the paywall resolve when the customer is not
  /// subscribed — target it from the dashboard.
  final String placement;

  /// Where the Stripe portal sends the customer back (defaults to the
  /// URL configured in your dashboard settings).
  final String? returnUrl;

  const PayloAccountView({
    super.key,
    this.paylo,
    this.customerId,
    this.placement = 'account',
    this.returnUrl,
  });

  @override
  State<PayloAccountView> createState() => _PayloAccountViewState();
}

class _PayloAccountViewState extends State<PayloAccountView> {
  late Future<CustomerStatus> _future;
  bool _changing = false;

  Paylo get _client => widget.paylo ?? Paylo.instance;
  String get _customerId =>
      widget.customerId ??
      _client.currentCustomerId ??
      (throw PayloException('customerId is required when Paylo.configure() was not used'));

  @override
  void initState() {
    super.initState();
    _future = _client.customerStatus(_customerId);
  }

  void _refresh() {
    setState(() => _future = _client.customerStatus(_customerId));
  }

  Future<void> _manage() async {
    final status = await _future;
    final sub = status.activeSubscription;
    if (sub == null) return;
    await _client.openPortal(sub.id, returnUrl: widget.returnUrl);
  }

  /// Plans the customer could switch to — everything except the current plan,
  /// lifetime plans (a sub can't become a one-time purchase) and plans in a
  /// different currency (Stripe refuses those). Uses the plans preloaded at
  /// configure() time; empty when the explicit-instance API is used.
  List<Plan> _otherPlans(CustomerStatus status) {
    if (!Paylo.isConfigured) return const [];
    final currentSlug = status.activePlan?.slug;
    final currentCurrency = status.activePlan?.currency;
    return Paylo.plans.where((p) {
      if (p.interval == 'one_time') return false;
      if (currentSlug != null && p.slug == currentSlug) return false;
      if (currentCurrency != null && p.currency != currentCurrency) return false;
      return true;
    }).toList();
  }

  /// Preview → confirm → apply, all handled here so the developer writes
  /// nothing. Upgrades show the proration; downgrades show the switch date.
  Future<void> _changePlanFlow(Plan target, String subscriptionId) async {
    PlanChange preview;
    try {
      preview = await _client.previewPlanChange(subscriptionId, target.slug);
    } catch (e) {
      _showError(e);
      return;
    }
    if (!mounted) return;

    final String message;
    if (preview.isImmediate) {
      if (preview.prorationAmount != null && preview.prorationAmount! > 0) {
        message =
            "You'll be charged ${_formatAmount(preview.prorationAmount!, preview.currency)} today, "
            "then ${_formatAmount(target.amount, target.currency)}${_intervalSuffix(target.interval)}.";
      } else {
        message = 'You\'ll switch to ${target.name} now.';
      }
    } else {
      final when = preview.effectiveAt != null
          ? _formatDate(preview.effectiveAt!)
          : 'the end of your current period';
      message = 'You\'ll switch to ${target.name} on $when.';
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Switch to ${target.name}?'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _changing = true);
    try {
      await _client.changePlan(subscriptionId, target.slug);
      _refresh();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    final msg = e is PayloException ? e.message : 'Something went wrong';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }

  String _formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  Widget _scheduledBanner(ScheduledChange sc, ThemeData theme, Color accent) {
    final name = sc.planName ?? 'your new plan';
    final when = sc.effectiveAt != null ? _formatDate(sc.effectiveAt!) : 'the end of your period';
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Switches to $name on $when',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _offersList(List<Plan> plans, String subscriptionId, ThemeData theme, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 20, bottom: 8),
          child: Text(
            'Other plans',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
        ),
        for (final p in plans)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _changing ? null : () => _changePlanFlow(p, subscriptionId),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        p.name,
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${_formatAmount(p.amount, p.currency)}${_intervalSuffix(p.interval)}',
                      style: TextStyle(fontSize: 13.5, color: theme.textTheme.bodySmall?.color),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right, size: 18, color: theme.dividerColor),
                  ],
                ),
              ),
            ),
          ),
        if (_changing)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Center(
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return FutureBuilder<CustomerStatus>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        if (snapshot.hasError || snapshot.data == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not load your subscription'),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _refresh, child: const Text('Retry')),
                ],
              ),
            ),
          );
        }

        final status = snapshot.data!;

        // No access → the paywall takes over the page.
        if (!status.hasActiveSubscription) {
          return PayloPaywall.inline(
            paylo: _client,
            customerId: _customerId,
            placement: widget.placement,
            onCheckoutOpened: (_) => _refresh(),
          );
        }

        final plan = status.activePlan;
        final isLifetime = plan?.interval == 'one_time';
        final theme = Theme.of(context);

        final String subline;
        if (isLifetime) {
          subline = 'Lifetime access — yours forever';
        } else if (status.isTrial && plan?.trialEnd != null) {
          subline = 'Free trial — first charge on ${_formatDate(plan!.trialEnd!)}';
        } else if (plan?.currentPeriodEnd != null) {
          subline = 'Renews on ${_formatDate(plan!.currentPeriodEnd!)}';
        } else {
          subline = 'Active';
        }

        final activeSubId = status.activeSubscription?.id;
        final others = (!isLifetime && status.canManage && status.scheduledChange == null)
            ? _otherPlans(status)
            : const <Plan>[];

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        isLifetime ? Icons.workspace_premium_outlined : Icons.autorenew,
                        color: accent,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  plan?.name ?? 'Subscription',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (status.isTrial) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    'TRIAL',
                                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: accent),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subline,
                            style: TextStyle(fontSize: 12.5, color: theme.textTheme.bodySmall?.color),
                          ),
                        ],
                      ),
                    ),
                    if (plan?.amount != null)
                      Text(
                        '${_formatAmount(plan!.amount!, plan.currency ?? 'eur')}${_intervalSuffix(plan.interval)}',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                  ],
                ),
              ),
              if (status.canManage) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _manage,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Manage subscription'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ],
              if (!isLifetime && status.scheduledChange != null)
                _scheduledBanner(status.scheduledChange!, theme, accent),
              if (others.isNotEmpty && activeSubId != null)
                _offersList(others, activeSubId, theme, accent),
            ],
          ),
        );
      },
    );
  }
}
