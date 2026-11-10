import 'package:flutter/material.dart';

import '../social/social_widgets.dart';
import 'chat_controller.dart';

class ChatPanel extends StatefulWidget {
  const ChatPanel(this.chat, {super.key});
  final ChatController chat;
  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final text = TextEditingController();
  final scroll = ScrollController();
  String? lastRendered;
  @override
  void initState() {
    super.initState();
    text.text = widget.chat.draft;
  }

  @override
  void dispose() {
    text.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> action(Map<String, dynamic> m, String value) async {
    if (value == 'report') {
      final reason = await socialReportReason(context);
      if (reason != null) await widget.chat.report(m['id'] as String, reason);
      return;
    }
    final reason = value == 'self' ? 'SELF' : await socialReportReason(context);
    if (reason == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover mensagem?'),
        content: const Text('O texto deixará de estar disponível no chat.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.chat.remove(
        m['id'] as String,
        reason == 'ILLEGAL' ? 'SAFETY' : reason,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chat;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final token = '${c.rows.lastOrNull?['id']}:${c.pending.length}';
        if (lastRendered != token &&
            !c.browsingOlder &&
            (!scroll.hasClients || scroll.position.extentAfter < 80)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && scroll.hasClients) {
              scroll.jumpTo(scroll.position.maxScrollExtent);
            }
          });
        }
        lastRendered = token;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      c.connected
                          ? 'Chat conectado'
                          : c.loading
                          ? 'Conectando ao chat…'
                          : 'Chat desconectado',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (c.loading) const LinearProgressIndicator(),
                  if (c.issue != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(switch (c.issue) {
                        'access_revoked' => 'Seu acesso ao chat foi encerrado. Atualize a experiência.',
                        'space_read_only' => 'O chat está em modo de leitura.',
                        'history_gap' => 'A conversa recebeu muitas mensagens. Consulte o histórico para continuar.',
                        'rate_limited' =>
                          'Aguarde antes de enviar outra mensagem.',
                        _ => 'Não foi possível concluir agora. Suas mensagens pendentes serão reconciliadas ao reconectar.',
                      }),
                    ),
                  if (!c.connected && !c.loading)
                    TextButton(
                      onPressed: c.reconnect,
                      child: const Text('Reconectar chat'),
                    ),
                  if (c.browsingOlder)
                    TextButton(
                      onPressed: c.reconnect,
                      child: const Text('Voltar às mensagens recentes'),
                    ),
                  if (c.before != null)
                    TextButton(
                      onPressed: c.busy ? null : c.older,
                      child: const Text('Carregar mensagens anteriores'),
                    ),
                  if (c.connected && c.rows.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'Comece a conversa com quem vai viver essa experiência.',
                      ),
                    ),
                  for (final m in c.rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (m['removed'] == true)
                                const Text('Mensagem removida')
                              else ...[
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        (m['author'] as Map)['display_name']
                                            as String,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge,
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: 'Ações da mensagem',
                                      onSelected: (v) => action(m, v),
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'report',
                                          child: Text('Denunciar mensagem'),
                                        ),
                                        if (m['can_delete'] == true)
                                          const PopupMenuItem(
                                            value: 'self',
                                            child: Text(
                                              'Excluir minha mensagem',
                                            ),
                                          ),
                                        if (m['can_moderate'] == true)
                                          const PopupMenuItem(
                                            value: 'moderate',
                                            child: Text('Remover do chat'),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                                SelectableText(m['body'] as String),
                                Text(
                                  TimeOfDay.fromDateTime(
                                    DateTime.parse(m['created_at'] as String)
                                        .toLocal(),
                                  ).format(context),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  for (final p in c.pending.values)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(p['body'] as String),
                      subtitle: Text(
                        p['state'] == 'failed'
                            ? 'Envio sem confirmação'
                            : 'Enviando…',
                      ),
                      trailing: p['state'] == 'failed'
                          ? IconButton(
                              tooltip: 'Tentar enviar novamente',
                              onPressed: c.canWrite
                                  ? () => c.retry(
                                      p['client_message_id'] as String,
                                    )
                                  : null,
                              icon: const Icon(Icons.refresh),
                            )
                          : const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                    ),
                ],
              ),
            ),
            if (c.canWrite)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: text,
                      minLines: 1,
                      maxLines: MediaQuery.viewInsetsOf(context).bottom > 0
                          ? 1
                          : 3,
                      maxLength: c.bodyLimit,
                      onChanged: (v) => c.draft = v,
                      decoration: const InputDecoration(
                        hintText: 'Mensagem no chat',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Enviar mensagem',
                    onPressed: () {
                      if (c.send(text.text)) {
                        c.draft = '';
                        text.clear();
                      }
                    },
                    icon: const Icon(Icons.send_outlined),
                  ),
                ],
              )
            else if (c.connected)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Chat em modo de leitura. As mensagens anteriores continuam disponíveis.',
                ),
              ),
          ],
        );
      },
    );
  }
}
