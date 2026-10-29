import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

// Approval is a product/environment decision, not inferred from a valid URL.
class LegalLinks extends StatelessWidget {
  const LegalLinks({super.key});
  static Uri? approvedUri(String raw) {
    final uri = Uri.tryParse(raw);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  @override
  Widget build(BuildContext context) {
    const approved = bool.fromEnvironment('LEGAL_LINKS_APPROVED');
    final terms = approvedUri(const String.fromEnvironment('TERMS_URL'));
    final privacy = approvedUri(const String.fromEnvironment('PRIVACY_URL'));
    if (!approved || terms == null || privacy == null) {
      return Text(
        'Termos e Política de Privacidade ainda não estão disponíveis.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    Future<void> open(Uri uri) async {
      var opened = false;
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        /* sanitized below */
      }
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Não foi possível abrir este documento. Tente novamente.',
            ),
          ),
        );
      }
    }

    return Wrap(
      spacing: 8,
      children: [
        TextButton(
          onPressed: () => open(terms),
          child: const Text('Termos de Uso'),
        ),
        TextButton(
          onPressed: () => open(privacy),
          child: const Text('Política de Privacidade'),
        ),
      ],
    );
  }
}
