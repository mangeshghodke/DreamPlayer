import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:dream_player/services/entitlements.dart';

/// Shows the paywall sheet. Returns true if the user purchased successfully.
///
/// Shows on Android only when `debugFreeUser` override is active (debug builds).
Future<bool> showPaywall(BuildContext context) async {
  final e = Entitlements.instance;
  // On Android: show only when the debug "simulate free user" override is active.
  if (defaultTargetPlatform == TargetPlatform.android && !e.debugFreeUser) {
    return false;
  }
  // On iOS: show only when paywall is effective (build-time define or debug).
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
        setState(() { _error = 'Store unavailable'; _loading = false; });
        return;
      }
      final ids = {
        'advanced_monthly',
        'advanced_yearly',
        'advanced_lifetime',
      };
      final response = await InAppPurchase.instance.queryProductDetails(ids);
      final products = response.productDetails.toList()
        ..sort((a, b) {
          // lifetime first, then yearly, then monthly
          const order = {'advanced_lifetime': 0, 'advanced_yearly': 1, 'advanced_monthly': 2};
          return (order[a.id] ?? 9).compareTo(order[b.id] ?? 9);
        });
      setState(() { _products = products; _loading = false; });
    } catch (e) {
      setState(() { _error = 'Failed to load products'; _loading = false; });
    }
  }

  Future<void> _buy(ProductDetails product) async {
    if (_purchasing) return;
    setState(() { _purchasing = true; _error = null; });
    try {
      final param = PurchaseParam(productDetails: product);
      InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
      // Wait for stream result
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
              setState(() { _purchasing = false; _error = 'Purchase failed'; });
              return;
            }
          }
        }
      }
    } catch (e) {
      setState(() { _purchasing = false; _error = 'Purchase failed'; });
    }
  }

  Future<void> _restore() async {
    setState(() { _purchasing = true; _error = null; });
    try {
      await InAppPurchase.instance.restorePurchases();
    } catch (e) {
      setState(() { _purchasing = false; _error = 'Restore failed'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Unlock DreamPlayer Advanced',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Dolby Vision, HDR10+, subtitle styling, A-B loop,\nsleep timer, downloads, and more.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(child: CircularProgressIndicator(color: Colors.white))
            else if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13))
            else
              ..._products.map((p) => _ProductTile(
                    product: p,
                    purchasing: _purchasing,
                    onTap: () => _buy(p),
                  )),
            const SizedBox(height: 12),
            // Debug-only: simulate a completed purchase (Android testing without StoreKit).
            if (kDebugMode && defaultTargetPlatform == TargetPlatform.android) ...[
              const Divider(color: Colors.white12, height: 1),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.greenAccent),
                  onPressed: () async {
                    // Flip the debug entitlement to advanced + mark a real purchase.
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
                child: const Text('Restore Purchases', style: TextStyle(color: Colors.white54)),
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

class _ProductTile extends StatelessWidget {
  final ProductDetails product;
  final bool purchasing;
  final VoidCallback onTap;

  const _ProductTile({
    required this.product,
    required this.purchasing,
    required this.onTap,
  });

  String get _label {
    switch (product.id) {
      case 'advanced_monthly':
        return 'Monthly';
      case 'advanced_yearly':
        return 'Yearly — Save 25%';
      case 'advanced_lifetime':
        return 'Lifetime — One-time purchase';
      default:
        return product.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: purchasing ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text(
                        product.price + (product.id != 'advanced_lifetime' ? '/mo' : ''),
                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                if (purchasing)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
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
