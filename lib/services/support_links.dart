import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:url_launcher/url_launcher.dart';

/// A donation / support option shown in Settings.
class SupportOption {
  const SupportOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.url,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String url;
}

/// All donation channels. Replace the placeholder URLs with your own:
///  - razorpay: create a Payment Link in the Razorpay dashboard
///      (Dashboard → Payment Links → Create) and paste the full `https://rzp.io/...`
///      URL here.
///  - githubSponsors: `https://github.com/sponsors/<your-username>`
const List<SupportOption> supportOptions = [
  SupportOption(
    title: 'Razorpay',
    subtitle: 'Pay via UPI, cards, or netbanking',
    icon: Icons.credit_card,
    url: 'https://rzp.io/rzp/cZ5afqVG',
  ),
  SupportOption(
    title: 'GitHub Sponsors',
    subtitle: 'Recurring support on GitHub',
    icon: Icons.favorite_outline,
    url: 'https://github.com/sponsors/mangeshghodke/',
  ),
];

/// Opens [url] in the browser (or the UPI app for `upi://` links).
Future<void> openSupportUrl(String url) async {
  final uri = Uri.parse(url);
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      throw PlatformException(code: 'cannot_open_url', message: url);
    }
  } catch (_) {
    // url_launcher not available on this platform - silently ignore.
  }
}
