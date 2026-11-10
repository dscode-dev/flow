import 'package:flutter/material.dart';

import '../../design/components.dart';
import '../explore/flow_playback.dart';
import 'social_media.dart';

class SocialAuthorTile extends StatelessWidget {
  const SocialAuthorTile(
    this.person, {
    required this.onOpen,
    this.trailing,
    this.subtitle,
    super.key,
  });
  final Map<String, dynamic> person;
  final Future<void> Function(String) onOpen;
  final Widget? trailing;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(
      child: Text(
        (person['display_name'] as String? ?? '?').characters.firstOrNull ??
            '?',
      ),
    ),
    title: Text(person['display_name'] as String? ?? 'Pessoa indisponível'),
    subtitle: subtitle != null
        ? Text(subtitle!)
        : person['handle'] != null
        ? Text('@${person['handle']}')
        : null,
    trailing: trailing,
    onTap: () => onOpen('/social/profiles/${person['user_id']}'),
  );
}

Future<String?> socialReportReason(BuildContext context) =>
    showFlowSheet<String>(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Denunciar', style: Theme.of(context).textTheme.titleLarge),
          for (final r in {
            'ABUSE': 'Abuso ou assédio',
            'SPAM': 'Spam',
            'PRIVACY': 'Privacidade',
            'ILLEGAL': 'Conteúdo ilegal',
            'OTHER': 'Outro motivo',
          }.entries)
            TextButton(
              onPressed: () => Navigator.pop(context, r.key),
              child: Text(r.value),
            ),
        ],
      ),
    );

class SocialPostCard extends StatelessWidget {
  const SocialPostCard(
    this.post, {
    required this.playback,
    required this.onOpen,
    required this.onLike,
    required this.onReport,
    required this.onEdit,
    required this.onDelete,
    this.onModerate,
    this.busy = false,
    this.detail = false,
    super.key,
  });
  final Map<String, dynamic> post;
  final FlowPlayback playback;
  final bool busy, detail;
  final Future<void> Function(String) onOpen;
  final VoidCallback onLike, onReport, onEdit, onDelete;
  final VoidCallback? onModerate;
  @override
  Widget build(BuildContext context) {
    final p = post;
    final media = (p['media'] as List).cast<Map<String, dynamic>>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SocialAuthorTile(
            p['author'] as Map<String, dynamic>,
            onOpen: onOpen,
            trailing: PopupMenuButton<String>(
              tooltip: 'Ações da publicação',
              onSelected: (v) {
                switch (v) {
                  case 'report':
                    onReport();
                  case 'edit':
                    onEdit();
                  case 'delete':
                    onDelete();
                  case 'hide':
                    onModerate?.call();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'report',
                  child: Text('Denunciar publicação'),
                ),
                if (p['can_manage'] == true) ...[
                  if (p['can_interact'] != false)
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('Editar texto'),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Excluir publicação'),
                  ),
                ],
                if (onModerate != null && p['can_context_moderate'] == true)
                  const PopupMenuItem(
                    value: 'hide',
                    child: Text('Ocultar no espaço'),
                  ),
              ],
            ),
          ),
          Text(
            '${DateTime.tryParse(p['created_at'] as String)?.toLocal().toString().substring(0, 16) ?? ''} · ${p['visibility'] == 'SPACE'
                ? 'Event Space'
                : p['visibility'] == 'PUBLIC'
                ? 'Público'
                : 'Seguidores'}${p['edited_at'] != null ? ' · editado' : ''}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          if ((p['body'] as String).isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                p['body'] as String,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          for (final m in media)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SocialMedia(
                p['id'] as String,
                m,
                playback: playback,
                key: ValueKey('${p['id']}:${m['id']}'),
              ),
            ),
          if (p['experience_id'] != null)
            TextButton.icon(
              onPressed: () => onOpen(
                '/experiences/${p['experience_id']}${p['context'] == 'EVENT_SPACE' ? '/space' : ''}',
              ),
              icon: Icon(
                p['context'] == 'EVENT_SPACE'
                    ? Icons.lock_outline
                    : Icons.event_outlined,
              ),
              label: Text(p['experience_title'] as String),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: busy || p['can_interact'] == false ? null : onLike,
                icon: Icon(
                  p['liked'] == true ? Icons.favorite : Icons.favorite_border,
                ),
                label: Text('${p['like_count']} curtidas'),
              ),
              TextButton.icon(
                onPressed: detail
                    ? null
                    : () => onOpen('/social/posts/${p['id']}'),
                icon: const Icon(Icons.chat_bubble_outline),
                label: Text('${p['comment_count']} comentários'),
              ),
            ],
          ),
          const Divider(),
        ],
      ),
    );
  }
}
