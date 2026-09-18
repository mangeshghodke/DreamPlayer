import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:dream_player/services/entitlements.dart';

/// Shows the paywall sheet. Returns true if the user purchased successfully.
///
/// Shows on Android only when `debugFreeUser` override is active (debug builds).
Future<bool> showPaywall(BuildContext context) async {
  final e = Entitlements.instance;
  if (defaultTargetPlatform == TargetPlatform.android && !e.debugFreeUser) {
    return false;
  }
  if (defaultTargetPlatform != TargetPlatform.android &&
      !e.effectivePaywallEnabled) {
    return false;
  }
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: const Color(0xFF1C1C1E),
    isScrollControlled: true,
    builder: (_) => const PaywallSheet(),
  );
  return result ?? false;
}

/// Feature list shown in the "What's included" popup.
const _kFeatures = [
  'Dolby Vision & HDR10+ playback',
  'HDR10 & HLG passthrough',
  'Subtitle styling (size, color, outline, delay)',
  'Playback speed control (0.25×–2×)',
  'A-B loop',
  'Sleep timer',
  'Download to device',
  'OpenSubtitles online search',
  'Priority updates & support',
];

class PaywallSheet extends StatefulWidget {
  const PaywallSheet({super.key});

  @override
  State<PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<PaywallSheet> {
  bool _loading = true;
  bool _purchasing = false;
  List<ProductDetails> _products = [];
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadProducts();
    // Tick every second to update the trial countdown live.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    try {
      final available = await InAppPurchase.instance.isAvailable();
      if (!available) {
        setState(() {
          _error = 'Store unavailable';
          _loading = false;
        });
        return;
      }
      const ids = {
        'advanced_monthly',
        'advanced_yearly',
        'advanced_lifetime',
      };
      final response =
          await InAppPurchase.instance.queryProductDetails(ids);
      final found = response.productDetails.toList();
      const order = {
        'advanced_lifetime': 0,
        'advanced_yearly': 1,
        'advanced_monthly': 2,
      };
      const placeholderPrices = {
        'advanced_lifetime': r'$49.99',
        'advanced_yearly': r'$14.99',
        'advanced_monthly': r'$1.99',
      };
      final products = <ProductDetails>[];
      for (final id in order.keys) {
        final match = found.where((p) => p.id == id);
        if (match.isNotEmpty) {
          products.add(match.first);
        } else {
          products.add(ProductDetails(
            id: id,
            title: id,
            description: '',
            price: placeholderPrices[id] ?? '',
            rawPrice: 0,
            currencyCode: 'INR',
          ));
        }
      }
      setState(() {
        _products = products;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Failed to load products';
        _loading = false;
      });
    }
  }

  bool _isPlaceholder(ProductDetails p) => p.rawPrice == 0;

  Future<void> _buy(ProductDetails product) async {
    if (_purchasing || _isPlaceholder(product)) return;
    setState(() {
      _purchasing = true;
      _error = null;
    });
    try {
      final param = PurchaseParam(productDetails: product);
      await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
      await for (final update in InAppPurchase.instance.purchaseStream) {
        for (final purchase in update) {
          if (purchase.productID == product.id) {
            if (purchase.status == PurchaseStatus.purchased ||
                purchase.status == PurchaseStatus.restored) {
              if (purchase.pendingCompletePurchase) {
                await InAppPurchase.instance.completePurchase(purchase);
              }
              if (mounted) Navigator.of(context).pop(true);
              return;
            }
            if (purchase.status == PurchaseStatus.error ||
                purchase.status == PurchaseStatus.canceled) {
              setState(() {
                _purchasing = false;
                _error = 'Purchase failed';
              });
              return;
            }
          }
        }
      }
    } catch (_) {
      setState(() {
        _purchasing = false;
        _error = 'Purchase failed';
      });
    }
  }

  Future<void> _startTrial() async {
    final navigator = Navigator.of(context);
    await Entitlements.instance.startTrial();
    if (mounted) navigator.pop(true);
  }

  void _showFeatures() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      builder: (_) => const _FeaturesSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = Entitlements.instance;
    final entitled = e.isAdvanced;
    final trialActive = e.trialActive;
    final trialRemaining = e.trialRemaining;
    final trialStarted = e.trialStarted;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row.
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Unlock DreamPlayer Premium',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (entitled)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Active',
                      style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  IconButton(
                    onPressed: _showFeatures,
                    icon: const Icon(Icons.info_outline,
                        color: Colors.white54, size: 22),
                    tooltip: "What's included",
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Dolby Vision, HDR10+, subtitle styling, A-B loop,\nsleep timer, downloads, and more.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),

            // ── Free Trial Block ──────────────────────────────────
            // Only show when trial is active OR not yet started.
            // Once expired → block disappears, only products remain.
            if (!entitled && (trialActive || !e.trialStartedEver))
              _buildTrialBlock(trialActive, trialStarted, trialRemaining),

            const SizedBox(height: 12),

            // ── Product Tiles ─────────────────────────────────────
            if (_loading)
              const Center(
                  child: CircularProgressIndicator(color: Colors.white))
            else if (_error != null)
              Text(_error!,
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 13))
            else
              ..._products.map((p) => _ProductTile(
                    product: p,
                    purchasing: _purchasing,
                    entitled: entitled,
                    isPlaceholder: _isPlaceholder(p),
                    onTap: () => _buy(p),
                  )),

            const SizedBox(height: 12),

            // Debug-only: simulate purchase on Android.
            if (kDebugMode &&
                defaultTargetPlatform == TargetPlatform.android) ...[
              const Divider(color: Colors.white12, height: 1),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.greenAccent),
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await Entitlements.instance.setDebugFreeUser(false);
                    if (!mounted) return;
                    navigator.pop(true);
                  },
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Simulate purchase (debug)'),
                ),
              ),
            ],

            Center(
              child: TextButton(
                onPressed: _purchasing ? null : () async {
                  final navigator = Navigator.of(context);
                  await InAppPurchase.instance.restorePurchases();
                  await Future<void>.delayed(const Duration(seconds: 2));
                  if (mounted) {
                    setState(() {});
                    if (Entitlements.instance.isAdvanced) {
                      navigator.pop(true);
                    }
                  }
                },
                child: const Text('Restore Purchases',
                    style: TextStyle(color: Colors.white54)),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Subscriptions auto-renew. Cancel anytime in your Apple ID settings.',
                style: TextStyle(color: Colors.white38, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrialBlock(
      bool trialActive, DateTime? trialStarted, Duration trialRemaining) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: trialActive
            ? Colors.greenAccent.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: trialActive
              ? Colors.greenAccent.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: trialActive
          ? _buildTrialActive(trialRemaining)
          : _buildTrialNotStarted(),
    );
  }

  Widget _buildTrialNotStarted() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.free_breakfast,
                color: Colors.greenAccent.withValues(alpha: 0.8), size: 20),
            const SizedBox(width: 8),
            const Text(
              '7-Day Free Trial',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Try all premium features free for 7 days.\nNo charge until the trial ends.',
          style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: _purchasing ? null : _startTrial,
            style: TextButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text(
              'Start Free Trial',
              style: TextStyle(
                color: Colors.black87,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTrialActive(Duration remaining) {
    final days = remaining.inDays;
    final hours = remaining.inHours % 24;
    final minutes = remaining.inMinutes % 60;
    final seconds = remaining.inSeconds % 60;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle,
                color: Colors.greenAccent.withValues(alpha: 0.9), size: 20),
            const SizedBox(width: 8),
            const Text(
              'Free Trial Active',
              style: TextStyle(
                color: Colors.greenAccent,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Countdown timer
        Row(
          children: [
            _countdownUnit(days, 'DAYS'),
            const SizedBox(width: 6),
            _countdownSeparator(),
            const SizedBox(width: 6),
            _countdownUnit(hours, 'HRS'),
            const SizedBox(width: 6),
            _countdownSeparator(),
            const SizedBox(width: 6),
            _countdownUnit(minutes, 'MIN'),
            const SizedBox(width: 6),
            _countdownSeparator(),
            const SizedBox(width: 6),
            _countdownUnit(seconds, 'SEC'),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'All premium features are unlocked. Subscribe to keep access after the trial.',
          style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
        ),
      ],
    );
  }

  Widget _countdownUnit(int value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.greenAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value.toString().padLeft(2, '0'),
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.greenAccent.withValues(alpha: 0.6),
              fontSize: 8,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _countdownSeparator() {
    return Text(':',
        style: TextStyle(
            color: Colors.greenAccent.withValues(alpha: 0.4),
            fontSize: 16,
            fontWeight: FontWeight.w700));
  }
}

/// Bottom sheet showing the feature list.
class _FeaturesSheet extends StatelessWidget {
  const _FeaturesSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "What's included",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon:
                      const Icon(Icons.close, color: Colors.white54, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._kFeatures.map(
              (f) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle,
                        color: Colors.greenAccent, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        f,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white10,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'Got it',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final ProductDetails product;
  final bool purchasing;
  final bool entitled;
  final bool isPlaceholder;
  final VoidCallback onTap;

  const _ProductTile({
    required this.product,
    required this.purchasing,
    required this.entitled,
    required this.isPlaceholder,
    required this.onTap,
  });

  String get _label {
    switch (product.id) {
      case 'advanced_monthly':
        return 'Monthly';
      case 'advanced_yearly':
        return 'Yearly — Best Value';
      case 'advanced_lifetime':
        return 'Lifetime — One-time purchase';
      default:
        return product.id;
    }
  }

  String get _priceDisplay {
    final base = product.price;
    if (product.id == 'advanced_yearly') return '$base/yr';
    if (product.id == 'advanced_lifetime') return base;
    return '$base/mo';
  }

  @override
  Widget build(BuildContext context) {
    final disabled = purchasing || entitled || isPlaceholder;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isPlaceholder ? Colors.white12 : Colors.white10,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: disabled ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_label,
                          style: TextStyle(
                              color: isPlaceholder
                                  ? Colors.white38
                                  : Colors.white,
                              fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text(
                        _priceDisplay,
                        style: TextStyle(
                            color: isPlaceholder
                                ? Colors.white38
                                : Colors.white54,
                            fontSize: 13),
                      ),
                    ],
                  ),
                ),
                if (entitled)
                  const Text('Active',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600))
                else if (isPlaceholder)
                  const Text('Soon',
                      style: TextStyle(color: Colors.white24, fontSize: 13))
                else if (purchasing)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white54),
                  )
                else
                  const Icon(Icons.chevron_right, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
