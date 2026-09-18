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
  if (defaultTargetPlatform != TargetPlatform.android && !e.effectivePaywallEnabled) {
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

  @override
  void initState() {
    super.initState();
    _loadProducts();
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
      final products = response.productDetails.toList()
        ..sort((a, b) {
          const order = {
            'advanced_lifetime': 0,
            'advanced_yearly': 1,
            'advanced_monthly': 2,
          };
          return (order[a.id] ?? 9).compareTo(order[b.id] ?? 9);
        });
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

  Future<void> _buy(ProductDetails product) async {
    if (_purchasing) return;
    setState(() {
      _purchasing = true;
      _error = null;
    });
    try {
      final param = PurchaseParam(productDetails: product);
      // Both subscriptions and non-consumable go through buyNonConsumable
      // on the purchaseStream; subscriptions auto-renew on Apple's side.
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

  Future<void> _restore() async {
    setState(() {
      _purchasing = true;
      _error = null;
    });
    try {
      await InAppPurchase.instance.restorePurchases();
      // Brief delay so StoreKit can process; Entitlements listener flips _advanced.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() {
          _purchasing = false;
        });
        if (Entitlements.instance.isAdvanced) {
          Navigator.of(context).pop(true);
        }
      }
    } catch (_) {
      setState(() {
        _purchasing = false;
        _error = 'Restore failed';
      });
    }
  }

  void _showFeatures() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      builder: (_) => _FeaturesSheet(products: _products),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entitled = Entitlements.instance.isAdvanced;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row — "Unlock" button or "Active" badge at top-right.
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                  TextButton(
                    onPressed: _showFeatures,
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white10,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Unlock',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Dolby Vision, HDR10+, subtitle styling, A-B loop,\nsleep timer, downloads, and more.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),

            if (_loading)
              const Center(
                  child: CircularProgressIndicator(color: Colors.white))
            else if (_error != null)
              Text(_error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13))
            else
              ..._products.map((p) => _ProductTile(
                    product: p,
                    purchasing: _purchasing,
                    entitled: entitled,
                    onTap: () => _buy(p),
                  )),

            const SizedBox(height: 12),

            // Debug-only: simulate purchase on Android.
            if (kDebugMode && defaultTargetPlatform == TargetPlatform.android) ...[
              const Divider(color: Colors.white12, height: 1),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton.icon(
                  style:
                      TextButton.styleFrom(foregroundColor: Colors.greenAccent),
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
                onPressed: _purchasing ? null : _restore,
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
}

/// Bottom sheet showing the feature list before purchase.
class _FeaturesSheet extends StatelessWidget {
  final List<ProductDetails> products;
  const _FeaturesSheet({required this.products});

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
                  icon: const Icon(Icons.close, color: Colors.white54, size: 20),
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
  final VoidCallback onTap;

  const _ProductTile({
    required this.product,
    required this.purchasing,
    required this.entitled,
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

  @override
  Widget build(BuildContext context) {
    final priceSuffix = product.id == 'advanced_lifetime' ? '' : '/mo';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: (purchasing || entitled) ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_label,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text(
                        '${product.price}$priceSuffix',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13),
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
